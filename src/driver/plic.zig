const memlayout = @import("../memlayout.zig");
const Cpu = @import("../process/cpu.zig");

pub fn init() void {
    // set desired IRQ priorities non-zero (otherwise disabled)
    @as(*u32, @ptrFromInt(memlayout.plic + memlayout.uart0_irq * 4)).* = 1;
    @as(*u32, @ptrFromInt(memlayout.plic + memlayout.virtio0_irq * 4)).* = 1;
}

pub fn initHart() void {
    const hart = Cpu.id();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    @as(
        *u32,
        @ptrFromInt(memlayout.plicSEnable(hart)),
    ).* = (1 << memlayout.uart0_irq) | (1 << memlayout.virtio0_irq);

    // set this hart's S-mode ptiority threshold to 0.
    @as(*u32, @ptrFromInt(memlayout.plicSPriority(hart))).* = 0;
}

///ask the PLIC what interrupt we should serve.
pub fn claim() u32 {
    const hart = Cpu.id();
    const irq_ptr: *u32 = @ptrFromInt(memlayout.plicSClaim(hart));
    return irq_ptr.*;
}

///tell the PLIC we've served this IRQ.
pub fn complete(irq: u32) void {
    const hart = Cpu.id();
    const irq_ptr: *u32 = @ptrFromInt(memlayout.plicSClaim(hart));
    irq_ptr.* = irq;
}
