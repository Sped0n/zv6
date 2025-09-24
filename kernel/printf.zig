const std = @import("std");
const Io = std.Io;
const SourceLocation = std.builtin.SourceLocation;

const console = @import("driver/console.zig");
const SpinLock = @import("lock/SpinLock.zig");

var panicked: bool = false;

var lock: SpinLock = undefined;
var lock_allowed_to_use: bool = true;

/// Io.Writer.drain implementation for the console
fn consoleDrain(_: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    _ = splat;
    // data.len > 0 is guaranteed by the interface
    const seg = data[0];
    for (seg) |b| console.putChar(b);
    return seg.len;
}

var console_writer: Io.Writer = .{
    .vtable = &.{ .drain = consoleDrain },
    .buffer = &.{}, // no buffer
};

pub fn init() void {
    lock.init("pr");
}

/// Print to the console.
pub fn printf(comptime format: []const u8, args: anytype) void {
    if (!lock_allowed_to_use) {
        console_writer.print(format, args) catch unreachable;
        return;
    }

    lock.acquire();
    defer lock.release();

    console_writer.print(format, args) catch unreachable;
}

/// Panic and halt the system.
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

/// Assertion.
pub fn assert(ok: bool, comptime src: SourceLocation) void {
    if (ok) return;
    lock_allowed_to_use = false;
    printf("Assertion failed at {s}:{d}", .{ src.file, src.line });
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}
