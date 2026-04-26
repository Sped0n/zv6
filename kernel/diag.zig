const std = @import("std");

const console = @import("console.zig");
const SpinLock = @import("lock/SpinLock.zig");
const Cpu = @import("process/Cpu.zig");
const riscv = @import("riscv.zig");

var lock: SpinLock = undefined;
var panicking: bool = false;
var panicked: bool = false;

const log = std.log.scoped(.diag);

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
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

    if (panicking) {
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

    {
        defer panicked = true;

        lock.acquire();
        defer lock.release();

        panicking = true;
        defer panicking = false;

        log.err(
            "========================================",
            .{},
        );

        log.err("CPU {d} panicked: {s}", .{ cpu_id, msg });
        log.err("Stack trace:", .{});
        log.err("  0x{x}", .{first_trace_addr orelse @returnAddress()});
        var fp = @frameAddress();
        for (0..63) |_| {
            if (fp == 0) break;

            const prev_fp: *const usize = @ptrFromInt(fp - 16);
            const return_addr: *const usize = @ptrFromInt(fp - 8);
            if (return_addr.* == 0) break;

            log.err("  0x{x}", .{return_addr.*});
            if (prev_fp.* <= fp) break;
            fp = prev_fp.*;
        }

        log.err(
            "========================================",
            .{},
        );
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
        log.err("Assertion failed", .{});
        unreachable;
    }
}

pub fn init() void {
    lock.init("diag");
    log.info("Diagnostics initialized", .{});
}
