const builtin = @import("std").builtin;

const Cpu = @import("proc.zig").Cpu;
const misc = @import("misc.zig");

locked: u32,
name: []const u8,
cpu: ?*Cpu,

const Self = @This();

pub fn init(self: *Self, name: []const u8) void {
    self.* = Self{
        .locked = 0,
        .name = name,
        .cpu = null,
    };
}

///Check whether this cpu is holding the lock.
///Interrupts must be off.
pub fn acquire(self: *Self) void {
    misc.pushOff();
    if (self.holding()) {} // TODO: panic

    while (@atomicRmw(
        u32,
        &self.locked,
        builtin.AtomicRmwOp.Xchg,
        1,
        builtin.AtomicOrder.acquire,
    ) != 0) {}
}

///Release the lock.
pub fn release(self: *Self) void {
    if (!self.holding()) {} // TODO: panic

    self.cpu = undefined;

    @atomicStore(
        u32,
        &self.locked,
        0,
        builtin.AtomicOrder.release,
    );

    misc.popOff();
}

pub fn holding(self: *Self) bool {
    return (self.locked > 0) and (self.cpu == Cpu.myCpu());
}
