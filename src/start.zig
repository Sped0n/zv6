const main = @import("main.zig");
const memlayout = @import("memlayout.zig");
const param = @import("param.zig");
const riscv = @import("riscv.zig");

export var stack0 align(16) = [_]u8{0} ** (4096 * param.n_cpu);

export fn start() callconv(.C) noreturn {
    // set M Previous Privilege mode to Supervisor. for mret.
    var mstatus = riscv.mstatus.read();
    mstatus &= ~(@intFromEnum(riscv.MStatusValue.mpp_machine_or_mask));
    mstatus |= @intFromEnum(riscv.MStatusValue.mpp_supervisor);
    riscv.mstatus.write(mstatus);

    // set M Exception Program Counter to main, for mret.
    riscv.mepc.write(@intFromPtr(&main.main));

    // disable paging for now.
    riscv.satp.write(0);

    // delegate all interrupts and exceptions to supervisor mode.
    riscv.medeleg.write(@as(u64, 0xffff));
    riscv.mideleg.write(@as(u64, 0xffff));
    riscv.sie.write(
        riscv.sie.read() | @intFromEnum(
            riscv.SieValue.seie,
        ) | @intFromEnum(
            riscv.SieValue.stie,
        ) | @intFromEnum(
            riscv.SieValue.ssie,
        ),
    );

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    riscv.pmpaddr0.write(@as(u64, 0x3fffffffffffff));
    riscv.pmpcfg0.write(@as(u64, 0xf));

    // ask for clock interrupts.
    timerInit();

    // keep each CPU's hartid in its tp register, for cpuid().
    const cpu_id = riscv.mhartid.read();
    riscv.tp.write(cpu_id);

    asm volatile ("mret");

    // should never reach here.
    unreachable;
}

fn timerInit() void {
    // enable supervisor-mode timer interrupts.
    riscv.mie.write(riscv.mie.read() | @intFromEnum(riscv.SieValue.stie));

    // enable the sstc extension (i.e. simecmp).
    riscv.menvcfg.write(riscv.menvcfg.read() | @as(u64, 1 << 63));

    // allow supervisor to use stimecmp and time.
    riscv.mcounteren.write(riscv.mcounteren.read() | @as(u64, 2));

    // ask for the very first timer interrupt.
    riscv.stimecmp.write(riscv.time.read() + @as(u64, 1000000));
}
