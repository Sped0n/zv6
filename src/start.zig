const param = @import("param.zig");
const main = @import("main.zig");
const riscv = @import("riscv.zig");
const memlayout = @import("memlayout.zig");

comptime {
    asm (
        \\         # qemu -kernel loads the kernel at 0x80000000
        \\         # and causes each hart (i.e. CPU) to jump there.
        \\         # kernel.ld causes the following code to
        \\         # be placed at 0x80000000.
        \\ .section .text
        \\ .global _start
        \\ _start:
        \\         # set up a stack for C.
        \\         # stack0 is declared in start.c,
        \\         # with a 4096-byte stack per CPU.
        \\         # sp = stack0 + (hartid * 4096)
        \\         la sp, stack0
        \\         li a0, 1024*4
        \\         csrr a1, mhartid
        \\         addi a1, a1, 1
        \\         mul a0, a0, a1
        \\         add sp, sp, a0
        \\         # jump to start() in start.zig
        \\         call start
        \\ spin:
        \\         j spin
    );
}

export var stack0 align(16) = [_]u8{0} ** (4096 * param.n_cpu);

export fn start() callconv(.C) noreturn {
    // set M Previous Privilege mode to Supervisor. for mret.
    var mstatus = riscv.rMstatus();
    mstatus &= ~(@intFromEnum(riscv.MStatus.mpp_machine_or_mask));
    mstatus |= @intFromEnum(riscv.MStatus.mpp_supervisor);
    riscv.wMstatus(mstatus);

    // set M Exception Program Counter to main, for mret.
    riscv.wMepc(@intFromPtr(&main.main));

    // disable paging for now.
    riscv.wSatp(0);

    // delegate all interrupts and exceptions to supervisor mode.
    riscv.wMedeleg(@as(u64, 0xffff));
    riscv.wMideleg(@as(u64, 0xffff));
    riscv.wSie(
        riscv.rSie() | @intFromEnum(
            riscv.Sie.seie,
        ) | @intFromEnum(
            riscv.Sie.stie,
        ) | @intFromEnum(
            riscv.Sie.ssie,
        ),
    );

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    riscv.wPmpaddr0(@as(u64, 0x3fffffffffffff));
    riscv.wPmpcfg0(@as(u64, 0xf));

    // ask for clock interrupts.
    // timerInit();

    // keep each CPU's hartid in its tp register, for cpuid().
    const id = riscv.rMhartid();
    riscv.wTp(id);

    // set sscratch to trap_frame
    riscv.wSscratch(memlayout.trap_frame);

    asm volatile ("mret");

    // should never reach here.
    unreachable;
}

fn timerInit() void {
    // enable supervisor-mode timer interrupts.
    riscv.wMie(riscv.rMie() | @intFromEnum(riscv.Sie.stie));

    // enable the sstc extension (i.e. simecmp).
    riscv.wMenvcfg(riscv.rMenvcfg() | @as(u64, 1 << 63));

    // allow supervisor to use stimecmp and time.
    riscv.wMcounteren(riscv.rMcounteren() | @as(u64, 2));

    // ask for the very first timer interrupt.
    riscv.wStimecmp(riscv.rTime() + @as(u64, 1000000));
}
