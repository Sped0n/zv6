const io = @import("std").io;
const fmt = @import("std").fmt;
const SourceLocation = @import("std").builtin.SourceLocation;

const console = @import("driver/console.zig");
const Spinlock = @import("lock/spinlock.zig");

var panicked: bool = false;

///lock to avoid interleaving concurrent prinrf's.
var lock: Spinlock = undefined;
var lock_allowed_to_use: bool = true;

// use Zig's fmt as a escape hatch (
const PrintfError = error{};
const Writer = io.Writer(
    void,
    PrintfError,
    writerCallback,
);
fn writerCallback(_: void, bytes: []const u8) PrintfError!usize {
    for (bytes) |byte| {
        console.putChar(byte);
    }
    return bytes.len;
}

///Print to the console.
pub fn printf(comptime format: []const u8, args: anytype) void {
    const local_lock_allowed_to_use = lock_allowed_to_use;
    if (local_lock_allowed_to_use) lock.acquire();
    defer {
        if (local_lock_allowed_to_use) lock.release();
    }

    fmt.format(
        Writer{ .context = {} },
        format,
        args,
    ) catch unreachable;
}

pub fn panic(
    comptime src: *const SourceLocation,
    comptime info: []const u8,
) noreturn {
    lock_allowed_to_use = false;
    printf("Panic from <{s}>: {s}\n", .{ src.fn_name, info });
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn checkPanicked() void {
    if (panicked) {
        while (true) {}
    }
}

pub fn assert(ok: bool, comptime src: *const SourceLocation) void {
    if (ok) return;
    lock_allowed_to_use = false;
    printf("Assertion failed: {s}:{s}", .{ src.file, src.line });
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn init() void {
    Spinlock.init(&lock, "pr");
}
