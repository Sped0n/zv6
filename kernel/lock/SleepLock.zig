const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const SpinLock = @import("SpinLock.zig");

locked: bool,
lock: SpinLock,

name: [*:0]const u8,
pid: u32,

const Self = @This();

pub fn init(self: *Self, comptime name: [*:0]const u8) void {
    self.lock.init("sleep lock");
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
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
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

    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    return self.locked and self.pid == proc.pid;
}
