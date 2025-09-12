const builtin = @import("std").builtin;

const fence = @import("../misc.zig").fence;
const panic = @import("../printf.zig").panic;
const Cpu = @import("../process/Cpu.zig");
const riscv = @import("../riscv.zig");

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
    pushOff();
    if (self.holding()) panic(
        @src(),
        "acquire while holding(lock: {s})",
        .{self.name},
    );

    while (@atomicRmw(
        bool,
        &self.locked,
        builtin.AtomicRmwOp.Xchg,
        true,
        builtin.AtomicOrder.acquire,
    ) != false) {}

    fence();

    // Record info about lock acquisition for holding() and debugging.
    self.cpu = Cpu.current();
}

/// Release the lock.
pub fn release(self: *Self) void {
    if (!self.holding()) panic(
        @src(),
        "not holding(lock: {s})",
        .{self.name},
    );

    self.cpu = null;

    fence();

    @atomicStore(
        bool,
        &self.locked,
        false,
        builtin.AtomicOrder.release,
    );

    popOff();
}

/// Check whether this cpu is holding the lock.
/// Interrupts must be off.
pub fn holding(self: *Self) bool {
    return self.locked and self.cpu == Cpu.current();
}

/// push_off/pop_off are like intr_off()/intr_on() except that they are matched:
/// it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
/// are initially off, then push_off, pop_off leaves them off.
pub fn pushOff() void {
    const old = riscv.intrGet();

    riscv.intrOff();
    const c = Cpu.current();
    if (c.noff == 0) c.intr_enable = old;
    c.noff += 1;
}

/// push_off/pop_off are like intr_off()/intr_on() except that they are matched:
/// it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
/// are initially off, then push_off, pop_off leaves them off.
pub fn popOff() void {
    const c = Cpu.current();
    if (riscv.intrGet()) {
        panic(@src(), "interruptible", .{});
    }
    if (c.noff < 1) {
        panic(@src(), "noff not matched", .{});
    }
    c.noff -= 1;
    if (c.noff == 0 and c.intr_enable) riscv.intrOn();
}
