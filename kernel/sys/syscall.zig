const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const assert = @import("../diag.zig").assert;
const fs = @import("../fs/fs.zig");
const vm = @import("../memory/vm.zig");
const param = @import("../param.zig");
const Process = @import("../process/Process.zig");
const sysfile = @import("sysfile.zig");
const sysproc = @import("sysproc.zig");

const log = std.log.scoped(.syscall);

pub const helpers = struct {
    pub const Error = error{
        AddressOverflow,
    };

    /// Fetch the u64 at addr from the current process.
    pub fn copyU64FromCurrentProcess(addr: u64) !u64 {
        const proc = Process.current() catch unreachable;
        assert(proc.page_table != null);
        if (addr >= proc.size or
            (addr + @sizeOf(u64)) > proc.size) return Error.AddressOverflow;
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
        const proc = Process.current() catch unreachable;
        assert(proc.page_table != null);
        return try vm.kvm.copyCStringFromUser(
            proc.page_table.?,
            buffer,
            addr,
        );
    }
};

pub const argument = struct {
    pub const Error = error{
        BadFileDescriptor,
        TooManyOpenFiles,
    };

    /// Fetch the system call argument n and return it as T (i32/u32/i64/u64, etc.).
    pub fn as(comptime T: type, n: usize) T {
        const proc = Process.current() catch unreachable;
        const trap_frame = proc.trap_frame.?;

        const raw: u64 = switch (n) {
            0 => trap_frame.a0,
            1 => trap_frame.a1,
            2 => trap_frame.a2,
            3 => trap_frame.a3,
            4 => trap_frame.a4,
            5 => trap_frame.a5,
            else => unreachable,
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
    pub fn asCString(n: usize, buffer: []u8) ![]const u8 {
        const addr: u64 = as(u64, n);
        return helpers.copyCStringFromCurrentProcess(addr, buffer);
    }

    /// Fetch the nth word-sized system call argument as a file descriptor
    pub fn asOpenedFile(n: usize, out_fd: ?*usize, out_file: ?**fs.File) !void {
        const fd: u64 = as(u64, n);
        const proc = Process.current() catch unreachable;
        if (fd >= proc.opened_files.len) return Error.BadFileDescriptor;
        if (proc.opened_files[fd]) |f| {
            if (out_fd) |ofd| ofd.* = fd;
            if (out_file) |of| of.* = f;
        } else {
            return Error.BadFileDescriptor;
        }
    }
};

pub const SyscallID = enum(u64) {
    fork = 1,
    exit = 2,
    wait = 3,
    pipe = 4,
    read = 5,
    kill = 6,
    exec = 7,
    fstat = 8,
    chdir = 9,
    dup = 10,
    getpid = 11,
    sbrk = 12,
    sleep = 13,
    uptime = 14,
    open = 15,
    write = 16,
    mknod = 17,
    unlink = 18,
    link = 19,
    mkdir = 20,
    close = 21,
};

pub fn syscall() !void {
    const proc = Process.current() catch unreachable(
        @src(),
        "current proc is null",
        .{},
    );
    const trap_frame = proc.trap_frame.?;

    errdefer trap_frame.a0 = @bitCast(@as(i64, -1));

    const syscall_id = meta.intToEnum(
        SyscallID,
        trap_frame.a7,
    ) catch |e| {
        log.err(
            "{d} {s}: Unknown syscall ID {d}",
            .{ proc.pid, proc.name, trap_frame.a7 },
        );
        return e;
    };

    errdefer |e| log.debug(
        "Syscall({s}) failed with {s}",
        .{ std.enums.tagName(SyscallID, syscall_id) orelse "null", @errorName(e) },
    );

    var tmp: u64 = 0;
    switch (syscall_id) {
        .fork => tmp = try sysproc.fork(),
        .exit => tmp = sysproc.exit(),
        .wait => tmp = try sysproc.wait(),
        .pipe => tmp = try sysfile.pipe(),
        .read => tmp = try sysfile.read(),
        .kill => tmp = try sysproc.kill(),
        .exec => tmp = try sysfile.exec(),
        .fstat => tmp = try sysfile.fileStat(),
        .chdir => tmp = try sysfile.chdir(),
        .dup => tmp = try sysfile.dup(),
        .getpid => tmp = try sysproc.getPid(),
        .sbrk => tmp = try sysproc.sbrk(),
        .sleep => tmp = try sysproc.sleep(),
        .uptime => tmp = sysproc.uptime(),
        .open => tmp = try sysfile.open(),
        .write => tmp = try sysfile.write(),
        .mknod => tmp = try sysfile.mknod(),
        .unlink => tmp = try sysfile.unlink(),
        .link => tmp = try sysfile.link(),
        .mkdir => tmp = try sysfile.mkdir(),
        .close => tmp = try sysfile.close(),
    }
    trap_frame.a0 = tmp;

    return;
}
