const assert = @import("printf.zig").assert;
const plic = @import("driver/plic.zig");
const uart = @import("driver/uart.zig");
const virtio_disk = @import("driver/virtio_disk.zig");
const SpinLock = @import("lock/SpinLock.zig");
const memlayout = @import("memlayout.zig");
const panic = @import("printf.zig").panic;
const printf = @import("printf.zig").printf;
const Cpu = @import("process/Cpu.zig");
const Process = @import("process/Process.zig");
const riscv = @import("riscv.zig");
const syscall = @import("sys/syscall.zig");

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
}

///set up to take exceptions and traps while in the kernel
pub fn initHart() void {
    riscv.stvec.write(@intFromPtr(&kernelVec));
}

///Handle an interrupt, exception, or system call from user space.
///called from trampoline.S
pub fn userTrap() void {
    if ((riscv.sstatus.read() & @intFromEnum(riscv.SStatusValue.spp)) != 0) {
        panic(@src(), "not from user mode", .{});
    }

    // send interrupt and exceptions to kernelTrap(),
    // since we're now in the kernel.
    riscv.stvec.write(@intFromPtr(kernelVec));

    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.trap_frame != null, @src());
    const trap_frame = proc.trap_frame.?;

    // save user program counter
    trap_frame.epc = riscv.sepc.read();

    var which_dev: WhichDev = .not_recognize;

    if (riscv.scause.read() == 8) {
        // system call

        if (proc.isKilled()) proc.exit(-1);

        // spec points to the ecall instruction,
        // but we want to return to the next instruction.
        trap_frame.epc += 4;

        // an interrupt will change sepc, scause, and sstatus,
        // so enable only now that we're done with those registers.
        riscv.intrOn();

        syscall.syscall();
    } else {
        which_dev = devIntr();

        if (which_dev == .not_recognize) {
            printf("usertrap(): unexpected scause {x}, pid={d}\n", .{ riscv.scause.read(), proc.pid });
            printf("            sepc={x} stval={x}", .{ riscv.sepc.read(), riscv.stval.read() });
            proc.setKilled();
        }
    }

    if (proc.isKilled()) proc.exit(-1);

    // give up the CPU if this is a timer interrupt.
    if (which_dev == .timer_intr) proc.yield();

    userTrapRet();
}

///return to user space
pub fn userTrapRet() void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.trap_frame != null, @src());
    assert(proc.page_table != null, @src());

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
    trap_frame.kernel_sp = proc.kstack + riscv.pg_size; // process's kernel stack
    trap_frame.kernel_trap = @intFromPtr(userTrap);
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
    const trampoline_userret = @as(*const fn (tp: u64, satp: u64) void, @ptrFromInt(
        memlayout.trampoline + (@intFromPtr(&userRet) - @intFromPtr(trampoline)),
    ));
    trampoline_userret(memlayout.trap_frame, satp);
}

pub export fn kernelTrap() void {
    const sepc = riscv.sepc.read();
    const sstatus = riscv.sstatus.read();
    const scause = riscv.scause.read();

    if ((sstatus & @intFromEnum(riscv.SStatusValue.spp)) == 0) {
        panic(
            @src(),
            "not from supervisor mode",
            .{},
        );
    }
    if (riscv.intrGet()) {
        panic(@src(), "interrupt enabled", .{});
    }

    const which_dev = devIntr();
    if (which_dev == .not_recognize) {
        // interrupt or trap from an unknown source
        printf(
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

        ticks += 1;
        Process.wakeUp(@intFromPtr(&ticks));
    }

    // ask for the next timer interrupt. this also clears
    // the interrupt request. 1000000 is about a tenth
    // of a second.
    riscv.stimecmp.write(riscv.time.read() + 1000000);
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
            printf("unexpected interrupt irq={d}\n", .{irq});
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
