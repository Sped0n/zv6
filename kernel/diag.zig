const std = @import("std");

const console = @import("driver/console.zig");
const SpinLock = @import("lock/SpinLock.zig");
const Cpu = @import("process/Cpu.zig");

var lock: SpinLock = undefined;
var lock_allow_to_use = true;
var panicked: bool = false;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_str = comptime switch (level) {
        .debug => "[DEBUG]",
        .info => "[INFO ]",
        .warn => "[WARN ]",
        .err => "[ERROR]",
    };

    const trimmed_scope = if (@tagName(scope).len <= 7) b: {
        break :b std.fmt.comptimePrint("{s: <7} | ", .{@tagName(scope)});
    } else b: {
        break :b std.fmt.comptimePrint("{s: <7}-| ", .{@tagName(scope)[0..7]});
    };

    if (!lock_allow_to_use) {
        console.writer.print(
            level_str ++ " " ++ trimmed_scope ++ fmt ++ "\n",
            args,
        ) catch unreachable;
    } else {
        lock.acquire();
        defer lock.release();

        console.writer.print(
            level_str ++ " " ++ trimmed_scope ++ fmt ++ "\n",
            args,
        ) catch unreachable;
    }
}

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const cpu_id = Cpu.id();

    logFn(.err, .diag, "CPU {d} panicked: {s}", .{ cpu_id, msg });

    {
        lock.acquire();
        defer lock.release();

        lock_allow_to_use = false;

        logFn(.err, .diag, "CPU {d} panicked: {s}", .{ cpu_id, msg });
        logFn(.err, .diag, "Stack trace:", .{});
        if (first_trace_addr) |first_addr| {
            var stack_iterator = std.debug.StackIterator.init(first_addr, @frameAddress());
            while (stack_iterator.next()) |addr| {
                logFn(.err, .diag, "  0x{x}", .{addr});
            }
        }

        panicked = true;
    }

    while (true) {}
}

pub fn checkPanicked() void {
    if (panicked) {
        while (true) {}
    }
}

pub fn assert(condition: bool) void {
    if (!condition) {
        logFn(.err, .diag, "Assertion failed", .{});
        unreachable;
    }
}

pub fn init() void {
    lock.init("diag");
    logFn(.debug, .diag, "Diagnostics initialized", .{});
}
