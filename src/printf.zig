const builtin = @import("std").builtin;
const SourceLocation = builtin.SourceLocation;

const console = @import("driver/console.zig");
const SpinLock = @import("lock/SpinLock.zig");

// the single worst formatted print on this planet -----------------------------

// NOTE: Why implement this shit(yeah i know it's bad)?
//       Cuz kernel will panic when using std.fmt.format(Zig 0.14.0).

const digits = "0123456789ABCDEF";

fn printInt(writeFn: *const fn (u8) void, xx: i64, base: u8, sgn: bool) void {
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    var neg = false;
    var x: u64 = undefined;

    if (sgn and xx < 0) {
        neg = true;
        x = @intCast(-xx);
    } else {
        x = @intCast(xx);
    }

    i = 0;
    while (true) {
        buf[i] = digits[x % base];
        i += 1;
        x /= base;
        if (x == 0) break;
    }

    if (neg) {
        buf[i] = '-';
        i += 1;
    }

    var j: isize = @intCast(i);
    while (j > 0) {
        j -= 1;
        writeFn(buf[@intCast(j)]);
    }
}

fn printPtr(writeFn: *const fn (u8) void, x: u64) void {
    writeFn('0');
    writeFn('x');

    var i: usize = 0;
    var val = x;
    while (i < (@sizeOf(u64) * 2)) : (i += 1) {
        const shift_amount = (@sizeOf(u64) * 8 - 4);
        const digit: usize = @intCast((val >> shift_amount) & 0xF);
        writeFn(digits[digit]);
        val <<= 4;
    }
}

///Only understands {d}, {x}, {*}, {s}, {c}, {b}, {o}.
pub fn vprintf(
    writeFn: *const fn (u8) void,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const fields_info = args_type_info.@"struct".fields;

    comptime var next_arg: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        const char = fmt[i];
        i += 1;

        if (char == '{') {
            if (i < fmt.len and fmt[i] == '{') {
                i += 1;
                writeFn('{');
                continue;
            }

            // Parse format specifier
            const start = i;
            inline while (i < fmt.len and fmt[i] != '}') : (i += 1) {}
            if (i >= fmt.len) @compileError("missing closing '}'");
            const specifier = fmt[start..i];
            i += 1; // Skip the closing '}'

            if (next_arg >= fields_info.len) {
                @compileError("Too few arguments for format string");
            }

            const field = fields_info[next_arg];
            const arg_value = @field(args, field.name);
            const T = @TypeOf(arg_value);
            next_arg += 1;

            if (specifier.len == 0 or specifier[0] == 'd') {
                // Decimal
                switch (T) {
                    i8, i16, i32, i64, isize => printInt(
                        writeFn,
                        @intCast(arg_value),
                        10,
                        true,
                    ),
                    u8, u16, u32, u64, usize => printInt(
                        writeFn,
                        @intCast(arg_value),
                        10,
                        false,
                    ),
                    else => @compileError("Unsupported type for decimal format"),
                }
            } else if (specifier[0] == 'x' or specifier[0] == 'X') {
                // Hex
                switch (@typeInfo(T)) {
                    .int, .comptime_int => printInt(
                        writeFn,
                        @intCast(arg_value),
                        16,
                        false,
                    ),
                    else => @compileError("Unsupported type for hex format"),
                }
            } else if (specifier[0] == '*') {
                // Pointer address
                switch (@typeInfo(T)) {
                    .pointer => printPtr(writeFn, @intFromPtr(arg_value)),
                    else => @compileError("Unsupported type for pointer format"),
                }
            } else if (specifier[0] == 's') {
                // String
                switch (@typeInfo(T)) {
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice, .c, .many => {
                            if (ptr_info.child == u8) {
                                var j: usize = 0;
                                while (j < arg_value.len) : (j += 1) {
                                    writeFn(arg_value[j]);
                                }
                            } else @compileError("Many items pointer child is not u8");
                        },
                        .one => switch (@typeInfo(ptr_info.child)) {
                            .array => |array_info| {
                                if (array_info.child == u8) {
                                    var j: usize = 0;
                                    while (j < arg_value.len) : (j += 1) {
                                        writeFn(arg_value[j]);
                                    }
                                } else @compileError("One item pointer child is not u8");
                            },
                            else => @compileError("One item pointer but not array"),
                        },
                    },
                    else => @compileError("Unsupported type for string format"),
                }
            } else if (specifier[0] == 'c') {
                // Character
                switch (T) {
                    u8 => writeFn(arg_value),
                    else => @compileError(
                        "Unsupported type for character format",
                    ),
                }
            } else if (specifier[0] == 'b') {
                // Binary
                switch (@typeInfo(T)) {
                    .int, .comptime_int => printInt(
                        writeFn,
                        @intCast(arg_value),
                        2,
                        false,
                    ),
                    else => @compileError("Unsupported type for binary format"),
                }
            } else if (specifier[0] == 'o') {
                // Octal
                switch (@typeInfo(T)) {
                    .int, .comptime_int => printInt(
                        writeFn,
                        @intCast(arg_value),
                        8,
                        false,
                    ),
                    else => @compileError("Unsupported type for octal format"),
                }
            } else {
                @compileError("Unknown format specifier: " ++ specifier);
            }
        } else if (char == '}') {
            if (i < fmt.len and fmt[i] == '}') {
                i += 1;
                writeFn('}');
                continue;
            }
            @compileError("Unexpected '}'");
        } else {
            writeFn(char);
        }
    }

    if (next_arg < fields_info.len) {
        @compileError("Too many arguments for format string");
    }
}

// exposed methods -------------------------------------------------------------

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

    vprintf(&console.putChar, format, args);
}

pub fn panic(
    comptime fn_name: ?[]const u8,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    lock_allowed_to_use = false;
    if (fn_name) |name| {
        printf("Panic from <{s}>: ", .{name});
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

pub fn assert(ok: bool, comptime src: *const SourceLocation) void {
    if (ok) return;
    lock_allowed_to_use = false;
    printf("Assertion failed: {s}:{d}", .{ src.file, src.line });
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn init() void {
    lock.init("pr");
}
