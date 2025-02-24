const param = @import("param.zig");
const Spinlock = @import("spinlock.zig");
const riscv = @import("riscv.zig");
const kalloc = @import("kalloc.zig");
const memlayout = @import("memlayout.zig");
const vm = @import("vm.zig");
const panic = @import("printf.zig").panic;

// Structs ---------------------------------------------------------------------

// Saved registers for kernel context switches.
pub const Context = extern struct {
    ra: u64,
    sp: u64,

    // callee-saved
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
};

// Per-CPU state.
pub const Cpu = struct {
    proc: ?*Proc, // The process running on this cpu, or null.
    context: Context, // swtch() here to enter scheduler().
    noff: u32, // Depth of push_off() nesting.
    intena: bool, // Were interrupts enabled before push_off()?

    var cpus: [param.n_cpu]Cpu = undefined; // container level interrupts

    const Self = @This();

    pub fn id() u64 {
        return riscv.rTp();
    }

    pub fn current() *Self {
        return &cpus[Self.id()];
    }
};

// Trapframe structure for handling traps
pub const Trapframe = extern struct {
    kernel_satp: u64, // kernel page table
    kernel_sp: u64, // top of process's kernel stack
    kernel_trap: u64, // usertrap()
    epc: u64, // saved user program counter
    kernel_hartid: u64, // saved kernel tp
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    s0: u64,
    s1: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
};

pub const ProcState = enum {
    UNUSED,
    USED,
    SLEEPING,
    RUNNABLE,
    RUNNING,
    ZOMBIE,
};

// Per-process state
pub const Proc = struct {
    lock: Spinlock,

    // p->lock must be held when using these:
    state: ProcState, // Process state
    chan: ?*anyopaque, // If non-zero, sleeping on chan
    killed: i32, // If non-zero, have been killed
    xstate: i32, // Exit status to be returned to parent's wait
    pid: i32, // Process ID

    // wait_lock must be held when using this:
    parent: ?*Proc, // Parent process

    // these are private to the process, so p->lock need not be held.
    kstack: u64, // Virtual address of kernel stack
    sz: u64, // Size of process memory (bytes)
    pagetable: riscv.PageTable, // User page table
    trapframe: ?*Trapframe, // data page for trampoline.S
    context: Context, // swtch() here to run process
    //ofile: [param.NOFILE]?*File, // Open files
    //cwd: ?*Inode, // Current directory
    name: [16]u8, // Process name (debugging)

    var procs: [param.n_proc]Proc = undefined; // container level variables
};

// Codes -----------------------------------------------------------------------

var pid_lock: Spinlock = undefined;

///helps ensure that wakeups of wait()ing
///parents are not lost. helps obey the
///memory model when using p->parent.
///must be acquired before any p->lock.
var wait_lock: Spinlock = undefined;

///Allocate a page for each process's kernel stack.
///Map it high in memory, followed by an invalid
///guard page.
pub fn mapStacks(kpgtbl: riscv.PageTable) void {
    // NOTE: don't try to iterate on uninitialized procs
    // see https://github.com/ziglang/zig/issues/13934
    for (0..param.n_proc) |i| {
        const phy_addr = kalloc.alloc();
        if (phy_addr == null) panic(&@src(), "kalloc failed");
        const virt_addr: u64 = memlayout.kStack(
            @intFromPtr(&Proc.procs[i]) - @intFromPtr(&Proc.procs[0]),
        );
        vm.kvmMap(
            kpgtbl,
            virt_addr,
            @intFromPtr(phy_addr.?),
            riscv.pg_size,
            @intFromEnum(
                riscv.PteFlag.r,
            ) | @intFromEnum(
                riscv.PteFlag.w,
            ),
        );
    }
}

pub fn init() void {
    // NOTE: don't try to iterate on uninitialized procs
    // see https://github.com/ziglang/zig/issues/13934
    Spinlock.init(&pid_lock, "nextpid");
    Spinlock.init(&wait_lock, "wait_lock");
    for (0..param.n_proc) |i| {
        const p = &(Proc.procs[i]);
        Spinlock.init(&(p.lock), "proc");
        p.state = .UNUSED;
        p.kstack = memlayout.kStack(
            @intFromPtr(p) - @intFromPtr(&Proc.procs[0]),
        );
    }
}
