const fs = @import("../fs/fs.zig");
const vm = @import("../memory/vm.zig");
const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;
const assert = @import("../printf.zig").assert;
const Process = @import("../process/Process.zig");

pub const Error = error{
    AddressOverflow,
    BadFileDescriptor,
    TooManyOpenFiles,
};

/// Fetch the u64 at addr from the current process.
pub fn copyU64FromCurrentProcess(addr: u64) !u64 {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.page_table != null, @src());
    if (addr >= proc.size or
        addr + @sizeOf(u64) > proc.size) return Error.AddressOverflow;
    var tmp: u64 = 0;
    try vm.kvm.copyFromUser(
        proc.page_table.?,
        @ptrCast(&tmp),
        addr,
        @sizeOf(u64),
    );
    return tmp;
}

/// Fetch the null-terminated string at addr from the current process.
pub fn copyCStringFromCurrentProcess(addr: u64, buffer: []u8) ![]const u8 {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.page_table != null, @src());
    return try vm.kvm.copyCStringFromUser(
        proc.page_table.?,
        buffer,
        addr,
    );
}

/// Fetch the system call argument n and return it as T (i32/u32/i64/u64, etc.).
pub fn syscallArgument(comptime T: type, n: usize) T {
    const proc = Process.current() catch panic(@src(), "current proc is null", .{});
    const trap_frame = proc.trap_frame.?;

    const raw: u64 = switch (n) {
        0 => trap_frame.a0,
        1 => trap_frame.a1,
        2 => trap_frame.a2,
        3 => trap_frame.a3,
        4 => trap_frame.a4,
        5 => trap_frame.a5,
        else => panic(@src(), "unknown arg index {d}", .{n}),
    };

    // T must be an integer type up to 64 bits
    comptime {
        const info = @typeInfo(T);
        if (info != .int) @compileError("argRaw(T,n): T must be an integer type");
        if (info.int.bits > 64) @compileError("argRaw(T,n): T wider than 64 bits");
    }

    const int_info = @typeInfo(T).int;

    if (int_info.bits == 64) {
        if (int_info.signedness == .signed) {
            return @bitCast(raw); // u64 -> i64
        } else {
            return raw; // u64 -> u64
        }
    } else {
        if (int_info.signedness == .signed) {
            return @truncate(@as(i64, @bitCast(raw))); // u64 -> i64 -> i32
        } else {
            return @truncate(raw); // u64 -> u32
        }
    }
}

/// Fetch the nth word-sized system call argument as a null-terminated string.
/// Copies into buf, at most max.
pub fn copyUserCStringFromArgument(n: usize, buf: []u8) ![]const u8 {
    const addr: u64 = syscallArgument(u64, n);
    return copyCStringFromCurrentProcess(addr, buf);
}

pub fn resolveOpenFileFromArgument(n: usize, out_fd: ?*usize, out_file: ?**fs.File) !void {
    const fd: u64 = syscallArgument(u64, n);
    if (fd >= param.n_ofile) return Error.BadFileDescriptor;
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    if (proc.ofiles[fd]) |f| {
        if (out_fd) |ofd| ofd.* = fd;
        if (out_file) |of| of.* = f;
    } else {
        return Error.BadFileDescriptor;
    }
}

pub fn reserveFileDescriptor(file: *fs.File) !usize {
    const proc = try Process.current();

    for (&proc.ofiles, 0..) |*f, fd| {
        if (f.* == null) {
            f.* = file;
            return fd;
        }
    }

    return Error.TooManyOpenFiles;
}
