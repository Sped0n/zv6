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

pub fn syscall() !void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    const trap_frame = proc.trap_frame.?;

    errdefer trap_frame.a0 = @bitCast(@as(i64, -1));

    const syscall_id = meta.intToEnum(
        SysCallID,
        trap_frame.a7,
    ) catch |e| {
        printf(
            "{d} {s}: unknown syscall ID {d}\n",
            .{ proc.pid, proc.name, trap_frame.a7 },
        );
        return e;
    };

    // errdefer |e| printf(
    //     "\nsyscall({s}) failed with {s}\n",
    //     .{ std.enums.tagName(SysCallID, syscall_id) orelse "null", @errorName(e) },
    // );

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
