const param = @import("param.zig");
const Spinlock = @import("spinlock.zig");
const riscv = @import("riscv.zig");
const kalloc = @import("kalloc.zig");
const memlayout = @import("memlayout.zig");
const vm = @import("vm.zig");
const panic = @import("uart.zig").dumbPanic;

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

    const Self = @This();

    pub fn cpuId() usize {
        return riscv.rTp();
    }

    pub fn myCpu() *Self {
        const id = Self.cpuId();
        return &cpus[id];
    }
};

pub var cpus: [param.n_cpu]Cpu = undefined;

// Trapframe structure for handling traps
pub const Trapframe = packed struct {
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
};

pub var procs: [param.n_proc]Proc = undefined;

pub fn mapStacks(kpgtbl: riscv.PageTable) void {
    // TODO: init procs

    // NOTE: don't try to iterate on uninitialized procs
    // see https://github.com/ziglang/zig/issues/13934
    for (0..param.n_proc) |i| {
        const phy_addr: usize = @intFromPtr(kalloc.kalloc() orelse {
            return panic("proc map stack kalloc err");
        });
        const virt_addr: usize = memlayout.kStack(
            @intFromPtr(&procs[i]) - @intFromPtr(&procs[0]),
        );
        vm.kvmMap(
            kpgtbl,
            virt_addr,
            phy_addr,
            riscv.pg_size,
            @intFromEnum(
                riscv.PteFlag.r,
            ) | @intFromEnum(
                riscv.PteFlag.w,
            ),
        );
    }
}
