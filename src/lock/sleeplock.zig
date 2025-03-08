const Process = @import("../process/process.zig");
const Spinlock = @import("spinlock.zig");

const panic = @import("../printf.zig").panic;

locked: bool,
lock: Spinlock,

name: []const u8,
pid: i32,

const Self = @This();

pub fn init(self: *Self, comptime name: []const u8) void {
    Spinlock.init(&self.lock);
    self.name = name;
    self.locked = false;
    self.pid = 0;
}

pub fn acquire(self: *Self) void {
    self.lock.acquire();
    defer self.lock.release();

    while (self.locked) Process.sleep(
        @intFromPtr(self),
        &self.lock,
    );
    self.locked = true;
    const proc = Process.current() catch panic("current proc is null");
    self.pid = proc.pid;
}

pub fn release(self: *Self) void {
    self.lock.acquire();
    defer self.lock.release();

    self.locked = false;
    self.pid = 0;
    Process.wakeUp(@intFromPtr(self));
}

pub fn holding(self: *Self) bool {
    self.lock.acquire();
    defer self.lock.release();

    const proc = Process.current() catch panic("current proc is null");
    return self.locked and self.pid == proc.pid;
}
