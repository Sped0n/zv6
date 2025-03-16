const std = @import("std");
const fmt = std.fmt;
const SourceLocation = std.builtin.SourceLocation;

const console = @import("driver/console.zig");
const SpinLock = @import("lock/SpinLock.zig");

const TerminalWriter = struct {
    const Self = @This();
    pub const Error = error{};

    pub fn write(_: Self, bytes: []const u8) !usize {
        for (bytes) |c| console.putChar(c);
        return bytes.len;
    }

    pub fn writeByte(self: Self, byte: u8) !void {
        _ = try self.write(&.{byte});
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) !void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: Self, bytes: []const u8) !void {
        _ = try self.write(bytes);
    }
};

var panicked: bool = false;

///lock to avoid interleaving concurrent prinrf's.
var lock: SpinLock = undefined;
var lock_allowed_to_use: bool = true;

///Print to the console.
pub fn printf(comptime format: []const u8, args: anytype) void {
    const local_lock_allowed_to_use = lock_allowed_to_use;
    if (local_lock_allowed_to_use) lock.acquire();
    defer {
        if (local_lock_allowed_to_use) lock.release();
    }

    fmt.format(
        @as(TerminalWriter, undefined),
        format,
        args,
    ) catch unreachable;
}

pub fn panic(
    comptime src: ?SourceLocation,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    lock_allowed_to_use = false;
    if (src) |s| {
        printf("Panic from <{s}[{s}]>: ", .{ s.fn_name, s.file });
    } else {
        printf("Panic: ", .{});
    }
    printf(format, args);
    printf("\n", .{});
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn checkPanicked() void {
    if (panicked) {
        while (true) {}
    }
}

pub fn assert(ok: bool, comptime src: SourceLocation) void {
    if (ok) return;
    lock_allowed_to_use = false;
    printf("Assertion failed at {s}:{d}", .{ src.file, src.line });
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn init() void {
    lock.init("pr");
}
