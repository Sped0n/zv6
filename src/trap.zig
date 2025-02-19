const riscv = @import("riscv.zig");

pub export fn kernelTrap() void {
    const sepc = riscv.rSepc();
    const sstatus = riscv.rSstatus();
    // const scause = riscv.rScause();

    if ((sstatus & @intFromEnum(riscv.SStatus.spp)) == 0) {
        // TODO: panic
    }

    riscv.wSepc(sepc);
    riscv.wSstatus(sstatus);
}
