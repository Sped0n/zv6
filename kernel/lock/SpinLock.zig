const std = @import("std");
const builtin = std.builtin;

const assert = @import("../diag.zig").assert;
const Cpu = @import("../process/Cpu.zig");
const riscv = @import("../riscv.zig");
const utils = @import("../utils.zig");

locked: bool,
name: [*:0]const u8,
cpu: ?*Cpu,

const Self = @This();

pub fn init(self: *Self, comptime name: [*:0]const u8) void {
    self.locked = false;
    self.name = name;
    self.cpu = null;
}

/// Check whether this cpu is holding the lock.
/// Interrupts must be off.
pub fn acquire(self: *Self) void {
    riscv.intrDisablePush();
    assert(!self.holding());

    while (@atomicRmw(
        bool,
        &self.locked,
        builtin.AtomicRmwOp.Xchg,
        true,
        builtin.AtomicOrder.acquire,
    ) != false) {}

    utils.fence();

    // Record info about lock acquisition for holding() and debugging.
    self.cpu = Cpu.current();
}

/// Release the lock.
pub fn release(self: *Self) void {
    assert(self.holding());

    self.cpu = null;

    utils.fence();

    @atomicStore(
        bool,
        &self.locked,
        false,
        builtin.AtomicOrder.release,
    );

    riscv.intrDisablePop();
}

/// Check whether this cpu is holding the lock.
/// Interrupts must be off.
pub fn holding(self: *Self) bool {
    return self.locked and self.cpu == Cpu.current();
}
