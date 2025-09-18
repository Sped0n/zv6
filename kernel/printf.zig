const std = @import("std");
const Io = std.Io;
const SourceLocation = std.builtin.SourceLocation;

const console = @import("driver/console.zig");
const SpinLock = @import("lock/SpinLock.zig");

var panicked: bool = false;

var lock: SpinLock = undefined;
var lock_allowed_to_use: bool = true;

var term_buf: [128]u8 = undefined;
var term_writer: Io.Writer = undefined;

/// Io.Writer.drain implementation for the console
fn terminalDrain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    // emit any bytes currently buffered in the interface
    if (w.end != 0) {
        const buf = w.buffer[0..w.end];
        for (buf) |b| console.putChar(b);
        w.end = 0;
    }

    // emit all segments except we handle the "splat" rule for the last one
    var consumed: usize = 0;

    if (data.len != 0) {
        // write all but the final segment
        for (data[0 .. data.len - 1]) |seg| {
            for (seg) |b| console.putChar(b);
            consumed += seg.len;
        }

        // last segment is written 'splat' times (may be zero)
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            for (last) |b| console.putChar(b);
        }
        // return number of bytes consumed from 'data' (exclude repeats); see Io.Writer docs.
        consumed += last.len;
    }

    return consumed;
}

pub fn init() void {
    lock.init("pr");

    term_writer = .{
        .vtable = &.{ .drain = terminalDrain },
        .buffer = &term_buf,
    };
}

/// Print to the console.
pub fn printf(comptime format: []const u8, args: anytype) void {
    if (!lock_allowed_to_use) {
        term_writer.print(format, args) catch unreachable;
        return;
    }

    lock.acquire();
    defer lock.release();

    term_writer.print(format, args) catch unreachable;
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
