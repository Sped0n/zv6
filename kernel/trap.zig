const std = @import("std");

const assert = @import("diag.zig").assert;
const plic = @import("driver/plic.zig");
const uart = @import("driver/uart.zig");
const virtio_disk = @import("driver/virtio_disk.zig");
const SpinLock = @import("lock/SpinLock.zig");
const memlayout = @import("memlayout.zig");
const Cpu = @import("process/Cpu.zig");
const Process = @import("process/Process.zig");
const riscv = @import("riscv.zig");
const syscall = @import("sys/syscall.zig");

const log = std.log.scoped(.trap);

// trampoline.S
const trampoline = @extern(*u8, .{ .name = "trampoline" });
extern fn userVec() void;
extern fn userRet() void;

// in kernelvec.S, calls kernelTrap().
extern fn kernelVec() void;

const WhichDev = enum { not_recognize, other_dev, timer_intr };

pub var ticks_lock: SpinLock = undefined;
pub var ticks: u32 = 0;

pub fn init() void {
    ticks_lock.init("time");
    log.info("Trap initialized", .{});
}

/// set up to take exceptions and traps while in the kernel
pub fn initHardwareThread() void {
    riscv.stvec.write(@intFromPtr(&kernelVec));
}

/// Handle an interrupt, exception, or system call from user space.
/// called from trampoline.S
pub fn userTrap() callconv(.c) void {
    // must from user mode
    assert(riscv.sstatus.read() & @intFromEnum(riscv.SStatusValue.spp) == 0);

    // send interrupt and exceptions to kernelTrap(),
    // since we're now in the kernel.
    riscv.stvec.write(@intFromPtr(&kernelVec));

    const proc = Process.current() catch unreachable;
    const trap_frame = proc.trap_frame.?;

    // save user program counter
    trap_frame.epc = riscv.sepc.read();

    var which_dev: WhichDev = .not_recognize;

    if (riscv.scause.read() == 8) {
        // system call

        if (proc.isKilled()) Process.exit(-1);

        // spec points to the ecall instruction,
        // but we want to return to the next instruction.
        trap_frame.epc += 4;

        // an interrupt will change sepc, scause, and sstatus,
        // so enable only now that we're done with those registers.
        riscv.intrOn();

        syscall.syscall() catch {};
    } else {
        which_dev = devIntr();

        if (which_dev == .not_recognize) {
            log.err("usertrap(): unexpected scause {x}, pid={d}, sepc={x}, stval={x}\n", .{
                riscv.scause.read(),
                proc.pid,
                riscv.sepc.read(),
                riscv.stval.read(),
            });
            proc.setKilled();
        }
    }

    if (proc.isKilled()) Process.exit(-1);

    // give up the CPU if this is a timer interrupt.
    if (which_dev == .timer_intr) Process.yield();

    userTrapRet();
}

/// return to user space
pub fn userTrapRet() callconv(.c) void {
    const proc = Process.current() catch unreachable;
    assert(proc.page_table != null);

    // we're about to switch the destination of traps from
    // kernelTrap() to userTrap(), so turn off interrupts until
    // we're back in user space, where userTrap() is correct.
    riscv.intrOff();

    // send syscalls, interrupts, and exceptions to uservec in trampoline.S
    const trampoline_uservec_addr: u64 = memlayout.trampoline + (@intFromPtr(
        &userVec,
    ) - @intFromPtr(
        trampoline,
    ));
    riscv.stvec.write(trampoline_uservec_addr);

    // set up trapframe values that uservec will need when
    // the process next traps into the kernel.
    const trap_frame = proc.trap_frame.?;
    trap_frame.kernel_satp = riscv.satp.read(); // kernel page table
    trap_frame.kernel_sp =
        proc.kernel_stack_virtual_addr + 2 * riscv.pg_size; // reset kernel stack to stack top
    trap_frame.kernel_trap = @intFromPtr(&userTrap);
    trap_frame.kernel_hartid = riscv.tp.read(); // hartid for Cpu.id()

    // set up the registers that trampoline.S's sret will use
    // to get to user space.

    // set S Previous Privilege mode to User.
    var sstatus = riscv.sstatus.read();
    sstatus &= ~@intFromEnum(riscv.SStatusValue.spp); // clear SPP to 0 for user mode
    sstatus |= @intFromEnum(riscv.SStatusValue.spie); // enable interrupts in user mode
    riscv.sstatus.write(sstatus);

    // set S Exception Program Counter to the saved user PC.
    riscv.sepc.write(trap_frame.epc);

    // tell trampoline.S the user page table switch to.
    const satp = riscv.makeSatp(proc.page_table.?);

    // jump to userRet in trampoline.S at the top of memory, which
    // switches to the user page table, restores user registers,
    // and switches to user mode with sret.
    const trampoline_userret = @as(
        *const fn (tp: u64, satp: u64) callconv(.c) void, // callconv is a must here!
        @ptrFromInt(
            memlayout.trampoline +
                (@intFromPtr(&userRet) - @intFromPtr(trampoline)),
        ),
    );
    trampoline_userret(memlayout.trap_frame, satp);
}

pub export fn kernelTrap() callconv(.c) void {
    const sepc = riscv.sepc.read();
    const sstatus = riscv.sstatus.read();
    const scause = riscv.scause.read();

    // must from supervisor mode
    assert(sstatus & @intFromEnum(riscv.SStatusValue.spp) != 0);

    // interrupts should be disabled now
    assert(!riscv.intrGet());

    const which_dev = devIntr();
    if (which_dev == .not_recognize) {
        // interrupt or trap from an unknown source
        log.err(
            "scause={x}, sepc={x}, stval={x}\n",
            .{ scause, riscv.sepc.read(), riscv.stval.read() },
        );
    } else if (which_dev == .timer_intr and Process.currentOrNull() != null) {
        // give up the CPU if this is a timer interrupt.
        Process.yield();
    }

    // the yield() may have caused some traps to occur,
    // so restore trap registers for use by kernelvec.S's sepc instruction.
    riscv.sepc.write(sepc);
    riscv.sstatus.write(sstatus);
}

fn clockIntr() void {
    if (Cpu.id() == 0) {
        ticks_lock.acquire();
        defer ticks_lock.release();

        ticks +%= 1;
        Process.wakeUp(@intFromPtr(&ticks));
    }

    // ask for the next timer interrupt. this also clears
    // the interrupt request. 1000000 is about a tenth
    // of a second.
    riscv.stimecmp.write(riscv.time.read() +% 1000000);
}

pub fn devIntr() WhichDev {
    const scause = riscv.scause.read();

    if (scause == 0x8000000000000009) {
        // this is a supervisor externel interrupt, via PLIC.

        // irq indicates which device interrupted.
        const irq = plic.claim();

        if (irq == memlayout.uart0_irq) {
            uart.intr();
        } else if (irq == memlayout.virtio0_irq) {
            virtio_disk.intr();
        } else if (irq > 0) {
            log.err("unexpected interrupt irq={d}\n", .{irq});
        }

        // the PLIC allows each device to raise at most one
        // interrupt at a time; tell the PLIC the device is
        // now allowed to interrupt again.
        if (irq > 0) plic.complete(irq);

        return .other_dev;
    } else if (scause == 0x8000000000000005) {
        // timer interrupt.
        clockIntr();
        return .timer_intr;
    } else {
        return .not_recognize;
    }
}
