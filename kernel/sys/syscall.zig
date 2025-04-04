const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const vm = @import("../memory/vm.zig");
const panic = @import("../printf.zig").panic;
const assert = @import("../printf.zig").assert;
const printf = @import("../printf.zig").printf;
const Process = @import("../process/Process.zig");
const sysfile = @import("sysfile.zig");
const sysproc = @import("sysproc.zig");

pub const SysCallID = enum(u64) {
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

pub const Error = error{
    AddressOverflow,
};

///Fetch the u64 at addr from the current process.
pub fn fetchRaw(addr: u64, dst: *u64) !void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.page_table != null, @src());
    if (addr >= proc.size or
        addr + @sizeOf(u64) > proc.size) return Error.AddressOverflow;
    try vm.copyIn(
        proc.page_table.?,
        @ptrCast(dst),
        addr,
        @sizeOf(u64),
    );
}

///Fetch the null-terminated string at addr from the current process.
pub fn fetchStr(addr: u64, dst: []u8) !void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    assert(proc.page_table != null, @src());
    try vm.copyInStr(
        proc.page_table.?,
        dst,
        addr,
    );
}

///Fetch the system call argument, return it as T
pub fn argRaw(comptime T: type, n: usize) T {
    @setRuntimeSafety(false);
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    switch (n) {
        0 => return @intCast(proc.trap_frame.a0),
        1 => return @intCast(proc.trap_frame.a1),
        2 => return @intCast(proc.trap_frame.a2),
        3 => return @intCast(proc.trap_frame.a3),
        4 => return @intCast(proc.trap_frame.a4),
        5 => return @intCast(proc.trap_frame.a5),
        else => panic(@src(), "unknown id({d})", .{n}),
    }
}

///Fetch the nth word-sized system call argument as a null-terminated string.
///Copies into buf, at most max.
pub fn argStr(n: usize, buf: []u8) !void {
    const addr: u64 = argRaw(u64, n);
    return fetchStr(addr, buf);
}

pub fn syscall() void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    const a7 = proc.trap_frame.a7;
    const a0 = &proc.trap_frame.a0;
    const syscall_id = meta.intToEnum(
        SysCallID,
        a7,
    ) catch {
        printf(
            "{d} {s}: unknown syscall ID {d}\n",
            .{ proc.pid, proc.name, proc.trap_frame.a7 },
        );
        @as(*i64, @ptrCast(a0)).* = -1;
        return;
    };

    // printf(
    //     "\n{d}({s}): syscall {s}\n",
    //     .{ proc.pid, proc.name, std.enums.tagName(SysCallID, syscall_id) orelse "null" },
    // );

    var _error: anyerror = undefined;
    ok_blk: {
        switch (syscall_id) {
            .fork => {
                a0.* = sysproc.fork() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .exit => {
                a0.* = sysproc.exit();
            },
            .wait => {
                a0.* = sysproc.wait() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .pipe => {
                a0.* = sysfile.pipe() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .read => {
                a0.* = sysfile.read() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .kill => {
                a0.* = sysproc.kill() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .exec => {
                a0.* = sysfile.exec() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .fstat => {
                a0.* = sysfile.fileStat() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .chdir => {
                a0.* = sysfile.chdir() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .dup => {
                a0.* = sysfile.dup() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .getpid => {
                a0.* = sysproc.getPid() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .sbrk => {
                a0.* = sysproc.sbrk() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .sleep => {
                a0.* = sysproc.sleep() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .uptime => {
                a0.* = sysproc.uptime();
            },
            .open => {
                a0.* = sysfile.open() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .write => {
                a0.* = sysfile.write() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .mknod => {
                a0.* = sysfile.mknod() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .unlink => {
                a0.* = sysfile.unlink() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .link => {
                a0.* = sysfile.link() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .mkdir => {
                a0.* = sysfile.mkdir() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
            .close => {
                a0.* = sysfile.close() catch |e| {
                    _error = e;
                    break :ok_blk;
                };
            },
        }

        return;
    }

    printf(
        "\nsyscall({s}) failed with {s}\n",
        .{ std.enums.tagName(SysCallID, syscall_id) orelse "null", @errorName(_error) },
    );
    @as(*i64, @ptrCast(a0)).* = -1;
}
