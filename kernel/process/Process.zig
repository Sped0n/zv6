const std = @import("std");
const builtin = std.builtin;
const mem = std.mem;
const math = std.math;

const File = @import("../fs/File.zig");
const fs = @import("../fs/fs.zig");
const Inode = @import("../fs/Inode.zig");
const log = @import("../fs/log.zig");
const path = @import("../fs/path.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const memlayout = @import("../memlayout.zig");
const kmem = @import("../memory/kmem.zig");
const vm = @import("../memory/vm.zig");
const misc = @import("../misc.zig");
const param = @import("../param.zig");
const assert = @import("../printf.zig").assert;
const printf = @import("../printf.zig").printf;
const panic = @import("../printf.zig").panic;
const riscv = @import("../riscv.zig");
const trap = @import("../trap.zig");
const Context = @import("context.zig").Context;
const Cpu = @import("Cpu.zig");
const sched = @import("scheduler.zig").sched;
const TrapFrame = @import("trapframe.zig").TrapFrame;

const initcode = @embedFile("initcode");

///trampoline.S
const trampoline = @extern(
    *u8,
    .{ .name = "trampoline" },
);

pub const ProcState = enum {
    unused,
    used,
    sleeping,
    runnable,
    running,
    zombie,
};

lock: SpinLock,

// p->lock must be held when using these:
state: ProcState, // Process state
chan_addr: u64, // If non-zero, sleeping on chan
killed: bool, // If non-zero, have been killed
exit_state: i32, // Exit status to be returned to parent's wait
pid: u32, // Process ID

// wait_lock must be held when using this:
parent: ?*Self, // Parent process

// these are private to the process, so p->lock need not be held.
kstack: u64, // Virtual address of kernel stack
size: u64, // Size of process memory (bytes)
page_table: ?riscv.PageTable, // User page table
trap_frame: *TrapFrame, // data page for trampoline.S
context: Context, // swtch() here to run process
ofiles: [param.n_ofile]?*File, // Open files
cwd: ?*Inode, // Current directory
name: [16]u8, // Process name (debugging)

pub var procs: [param.n_proc]Self = [_]Self{Self{
    .lock = undefined,
    .state = .unused,
    .chan_addr = 0,
    .killed = false,
    .exit_state = 0,
    .pid = 0,
    .parent = null,
    .kstack = 0,
    .size = 0,
    .page_table = null,
    .trap_frame = undefined,
    .context = undefined,
    .ofiles = undefined,
    .cwd = null,
    .name = [_]u8{0} ** 16,
}} ** param.n_proc;

var init_proc: *Self = undefined;

var nextpid: u32 = 1;
var pid_lock: SpinLock = undefined;

///helps ensure that wakeups of wait()ing
///parents are not lost. helps obey the
///memory model when using p->parent.
///must be acquired before any p->lock.
var wait_lock: SpinLock = undefined;

const Self = @This();

pub const Error = error{
    CurrentProcIsNull,
    NoChildAvailable,
    PidOutOfRange,
    NoProcAvailable,
};

///Allocate two pages for each process's kernel stack.
///Map it high in memory, followed by an invalid
///guard page.
pub fn mapStacks(kpgtbl: riscv.PageTable) !void {
    // NOTE: don't try to iterate on uninitialized procs
    // see https://github.com/ziglang/zig/issues/13934
    for (0..param.n_proc) |i| {
        const page0 = try kmem.alloc();
        const page1 = try kmem.alloc();
        errdefer {
            kmem.free(page0);
            kmem.free(page1);
        }
        const virt_addr = memlayout.kernelStack(i);
        vm.kvmMap(
            kpgtbl,
            virt_addr,
            @intFromPtr(page0),
            riscv.pg_size,
            @intFromEnum(
                riscv.PteFlag.r,
            ) | @intFromEnum(
                riscv.PteFlag.w,
            ),
        );
        vm.kvmMap(
            kpgtbl,
            virt_addr + riscv.pg_size,
            @intFromPtr(page1),
            riscv.pg_size,
            @intFromEnum(
                riscv.PteFlag.r,
            ) | @intFromEnum(
                riscv.PteFlag.w,
            ),
        );
    }
}

///initialize the proc table
pub fn init() void {
    // NOTE: don't try to iterate on uninitialized procs
    // see https://github.com/ziglang/zig/issues/13934
    pid_lock.init("nextpid");
    wait_lock.init("wait_lock");
    for (0..param.n_proc) |i| {
        const proc = &(procs[i]);
        proc.lock.init("proc");
        proc.kstack = memlayout.kernelStack(i);
    }
}

///Return the current struct proc *.
pub fn current() !*Self {
    SpinLock.pushOff();
    defer SpinLock.popOff();

    if (Cpu.current().proc) |proc| {
        return proc;
    } else {
        return Error.CurrentProcIsNull;
    }
}

///Return the current struct proc *, or null if none.
pub fn currentOrNull() ?*Self {
    SpinLock.pushOff();
    defer SpinLock.popOff();

    return Cpu.current().proc;
}

pub fn allocPid() u32 {
    pid_lock.acquire();
    defer pid_lock.release();

    const pid = nextpid;
    assert(pid != math.maxInt(u32), @src());
    nextpid += 1;
    return pid;
}

fn create() !*Self {
    var proc: *Self = undefined;

    traverse_blk: {
        for (0..param.n_proc) |i| {
            proc = &procs[i];
            proc.lock.acquire();
            if (proc.state == .unused) {
                break :traverse_blk;
            } else {
                proc.lock.release();
            }
        }
        return Error.NoProcAvailable;
    }

    proc.pid = allocPid();
    proc.state = .used;

    // Allocate a trapframe page.
    proc.trap_frame = @ptrCast(@alignCast(kmem.alloc() catch |e| {
        proc.free();
        proc.lock.release();
        return e;
    }));

    // An empty user page table.
    proc.page_table = createPageTable(proc) catch |e| {
        proc.free();
        proc.lock.release();
        return e;
    };

    // Set up new context to start executing at forkret,
    // which returns to user space.
    @memset(@as(
        [*]u8,
        @ptrCast(&proc.context),
    )[0..@sizeOf(@TypeOf(proc.context))], 0);
    proc.context.ra = @intFromPtr(&forkRet);
    proc.context.sp = proc.kstack + 2 * riscv.pg_size;

    return proc;
}

///free a proc structure and the data hanging from it,
///including user pages.
///p->lock must be held.
fn free(self: *Self) void {
    kmem.free(@ptrCast(self.trap_frame));
    self.trap_frame = undefined;

    if (self.page_table) |pt|
        freePageTable(pt, self.size);
    self.page_table = null;

    self.size = 0;
    self.pid = 0;
    self.parent = null;
    @memset(&self.name, 0);
    self.chan_addr = 0;
    self.killed = false;
    self.exit_state = 0;
    self.state = .unused;
}

///Create a user page table for a given process, with no user memory,
///but with trampoline and trapframe pages.
pub fn createPageTable(self: *Self) !riscv.PageTable {
    // An empty page table.
    const page_table = try vm.uvmCreate();

    // map the trampoline code (for system call return)
    // at the highest user virtual address.
    // only the supervisor uses it, on the way
    // to/from user space, so not PTE_U.
    vm.mapPages(
        page_table,
        memlayout.trampoline,
        riscv.pg_size,
        @intFromPtr(trampoline),
        @intFromEnum(riscv.PteFlag.r) | @intFromEnum(riscv.PteFlag.x),
    ) catch |e| {
        vm.uvmFree(page_table, 0);
        return e;
    };

    // map the trapframe page just below the trampoline page, for
    // trampoline.S.
    vm.mapPages(
        page_table,
        memlayout.trap_frame,
        riscv.pg_size,
        @intFromPtr(self.trap_frame),
        @intFromEnum(riscv.PteFlag.r) | @intFromEnum(riscv.PteFlag.w),
    ) catch |e| {
        vm.uvmFree(page_table, 0);
        return e;
    };

    return page_table;
}

///Free a process's page table, and free the
///physical memory it refers to.
pub fn freePageTable(page_table: riscv.PageTable, size: u64) void {
    vm.uvmUnmap(page_table, memlayout.trampoline, 1, false);
    vm.uvmUnmap(page_table, memlayout.trap_frame, 1, false);
    vm.uvmFree(page_table, size);
}

///Set up first user process.
pub fn userInit() void {
    const proc = Self.create() catch |e| panic(
        @src(),
        "Process.create failed with {s}",
        .{@errorName(e)},
    );
    assert(proc.page_table != null, @src());
    init_proc = proc;

    // allocate one user page and copy initcode's instructions
    // and data into it.
    vm.uvmFirst(proc.page_table.?, initcode);
    proc.size = riscv.pg_size;

    // prepare for the very first "return" from kernel to user.
    proc.trap_frame.epc = 0; // user program counter
    proc.trap_frame.sp = riscv.pg_size; // user stack pointer

    misc.safeStrCopy(&proc.name, "initcode");
    proc.cwd = path.toInode("/") catch |e| panic(
        @src(),
        "path.namei failed with {s}",
        .{@errorName(e)},
    );

    proc.state = .runnable;

    proc.lock.release();
}

///Grow or shrink user memory by n bytes.
pub fn growCurrent(n: i32) !void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    assert(proc.page_table != null, @src());

    var size = proc.size;
    if (n > 0) {
        size = try vm.uvmMalloc(
            proc.page_table.?,
            size,
            size + @abs(n),
            @intFromEnum(riscv.PteFlag.w),
        );
    } else if (n < 0) {
        size = vm.uvmDealloc(
            proc.page_table.?,
            size,
            size - @abs(n),
        );
    }

    proc.size = size;
}

///Create a new process, copying the parent.
///Sets up child kernel stack to return as if from fork() system call.
pub fn fork() !u32 {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.page_table != null, @src());
    assert(proc.cwd != null, @src());

    var new_proc: *Self = undefined;
    var pid: u32 = 0;

    {
        // Allocate process.
        new_proc = try create();
        defer new_proc.lock.release();

        // Copy user memory from parent to child.
        vm.uvmCopy(
            proc.page_table.?,
            new_proc.page_table.?,
            proc.size,
        ) catch |e| {
            free(new_proc);
            new_proc.lock.release();
            return e;
        };
        new_proc.size = proc.size;

        // Copy saved user register.
        new_proc.trap_frame.* = proc.trap_frame.*;

        // Cause fork to return 0 in the child.
        new_proc.trap_frame.a0 = 0;

        // Increment reference counts on open file descriptors.
        for (0..param.n_ofile) |i| {
            if (proc.ofiles[i]) |ofile| {
                new_proc.ofiles[i] = ofile.dup();
            }
        }
        new_proc.cwd = proc.cwd.?.dup();

        // Copy name from parent process.
        misc.safeStrCopy(&new_proc.name, mem.sliceTo(&proc.name, 0));

        // Create a copy of PID inside lock guard.
        pid = new_proc.pid;
    }

    {
        wait_lock.acquire();
        defer wait_lock.release();

        new_proc.parent = proc;
    }

    {
        new_proc.lock.acquire();
        defer new_proc.lock.release();

        new_proc.state = .runnable;
    }

    return pid;
}

///Pass p's abandoned children to init.
///Caller must hold wait_lock.
pub fn reParent(self: *Self) void {
    for (0..param.n_proc) |i| {
        const proc = &procs[i];
        if (proc.parent == self) {
            proc.parent = init_proc;
            wakeUp(@intFromPtr(init_proc));
        }
    }
}

///Exit the current process.  Does not return.
///An exited process remains in the zombie state
///until its parent calls wait().
pub fn exit(status: i32) void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.parent != null, @src());
    assert(proc.cwd != null, @src());

    if (proc == init_proc) panic(@src(), "init exiting", .{});

    for (0..param.n_ofile) |fd| {
        if (proc.ofiles[fd]) |ofile| {
            ofile.close();
            proc.ofiles[fd] = null;
        }
    }

    {
        log.beginOp();
        defer log.endOp();

        proc.cwd.?.put();
    }

    proc.cwd = null;

    {
        wait_lock.acquire();
        defer wait_lock.release();

        // Give any children to init.
        reParent(proc);

        // Parent might be sleeping in wait()
        wakeUp(@intFromPtr(proc.parent.?));

        proc.lock.acquire();

        proc.exit_state = status;
        proc.state = .zombie;
    }

    // Jump into the scheduler, never to return.
    sched();
    panic(@src(), "zombie exit", .{});
}

// Wait for a child process to exit and return its pid.
// Return null if this process has no children.
pub fn wait(addr: u64) !u32 {
    const curr_proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(curr_proc.page_table != null, @src());

    wait_lock.acquire();
    defer wait_lock.release();

    while (true) {
        // scan through table looking for exited children.
        var have_kids = false;
        for (0..param.n_proc) |i| {
            const proc = &procs[i];

            if (proc.parent != curr_proc) continue;
            // make sure the child isn't still in exit() or swtch().
            proc.lock.acquire();
            defer proc.lock.release();

            have_kids = true;
            if (proc.state != .zombie) continue;

            // Found one.
            const pid = proc.pid;
            if (addr != 0) {
                try vm.copyOut(
                    curr_proc.page_table.?,
                    addr,
                    @ptrCast(&proc.exit_state),
                    @sizeOf(@TypeOf(proc.exit_state)),
                );
            }

            proc.free();
            return pid;
        }

        // No point waiting if we don't have any children.
        if (!have_kids or curr_proc.isKilled()) {
            return Error.NoChildAvailable;
        }

        // Wait for a child to exit
        sleep(@intFromPtr(curr_proc), &wait_lock);
    }
}

///Give up the CPU for one scheduling round.
pub fn yield() void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    proc.lock.acquire();
    defer proc.lock.release();

    proc.state = .runnable;
    sched();
}

///A fork child's very first scheduling by scheduler()
///will swtch to forkret.
pub fn forkRet() callconv(.c) void {
    const S = struct {
        var first: bool = true;
    };

    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    // Still holding p->lock from scheduler.
    proc.lock.release();

    if (@atomicLoad(
        bool,
        &S.first,
        builtin.AtomicOrder.acquire,
    ) == true) {
        // File system initialization must be run in the context of a
        // regular process (e.g., because it calls sleep), and thus cannot
        // be run from main().
        fs.init(param.root_dev);

        // ensure other core see it.
        @atomicStore(
            bool,
            &S.first,
            false,
            builtin.AtomicOrder.release,
        );
    }

    trap.userTrapRet();
}

///Atomically release lock and sleep on chan.
///Reacquires lock when awakened.
pub fn sleep(chan_addr: u64, lock: *SpinLock) void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    proc.lock.acquire(); // DOC: sleeplock 1
    lock.release();
    defer {
        // Reacquire original lock.
        proc.lock.release();
        lock.acquire();
    }

    // Go to sleep.
    proc.chan_addr = chan_addr;
    proc.state = .sleeping;

    sched();

    // Tidy up.
    proc.chan_addr = 0;
}

///Wake up all processes sleeping on chan.
///Must be called without any p->lock.
pub fn wakeUp(chan_addr: u64) void {
    for (0..param.n_proc) |i| {
        const proc = &procs[i];
        if (proc != currentOrNull()) {
            proc.lock.acquire();
            defer proc.lock.release();

            if (proc.state == .sleeping and
                proc.chan_addr == chan_addr) proc.state = .runnable;
        }
    }
}

///Kill the process with the given pid.
///The victim won't exit until it tries to return
///to user space (see userTrap() in trap.zig).
pub fn kill(pid: u32) !void {
    for (0..param.n_proc) |i| {
        const proc = &procs[i];

        proc.lock.acquire();
        defer proc.lock.release();

        if (proc.pid != pid) continue;

        proc.killed = true;
        // Wake process from sleep().
        if (proc.state == .sleeping) proc.state = .runnable;
        return;
    }
    return Error.PidOutOfRange;
}

pub fn setKilled(self: *Self) void {
    self.lock.acquire();
    defer self.lock.release();

    self.killed = true;
}

pub fn isKilled(self: *Self) bool {
    self.lock.acquire();
    defer self.lock.release();

    return self.killed;
}

///Copy to either a user address, or kernel address,
///depending on usr_dst.
///Returns true on success, false on error.
pub fn eitherCopyOut(
    is_user_dst: bool,
    dst_addr: u64,
    src: [*]const u8,
    len: u64,
) !void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    if (is_user_dst) {
        assert(proc.page_table != null, @src());
        try vm.copyOut(
            proc.page_table.?,
            dst_addr,
            src,
            len,
        );
    } else {
        misc.memMove(@ptrFromInt(dst_addr), src, len);
    }
}

///Copy from either a user address, or kernel address,
///depending on usr_src.
///Returns true on success, false on error.
pub fn eitherCopyIn(dst: [*]u8, is_user_src: bool, src_addr: u64, len: u64) !void {
    const proc = current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    if (is_user_src) {
        assert(proc.page_table != null, @src());
        try vm.copyIn(
            proc.page_table.?,
            dst,
            src_addr,
            len,
        );
    } else {
        misc.memMove(dst, @ptrFromInt(src_addr), len);
    }
}

///Print a process listing to console.  For debugging.
///Runs when user types ^P on console.
///No lock to avoid wedging a stuck machine further.
pub fn dump() void {
    printf("\n", .{});
    for (0..param.n_proc) |i| {
        const proc = procs[i];

        if (proc.state == .unused) continue;
        printf("{d: <7} {s: ^10} {s}\n", .{ proc.pid, @tagName(proc.state), proc.name });
    }
}
