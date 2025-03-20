const Process = @import("../process/Process.zig");
const ticks = @import("../trap.zig").ticks;
const ticks_lock = @import("../trap.zig").ticks_lock;
const argRaw = @import("syscall.zig").argRaw;

pub const Error = error{
    ProcIsKilled,
};

pub fn exit() u64 {
    const n: i32 = @intCast(argRaw(0));
    Process.exit(n);
    return 0;
}

pub fn getPid() !u64 {
    return @intCast((try Process.current()).pid);
}

pub fn fork() !u64 {
    return @intCast(try Process.fork());
}

pub fn wait() !u64 {
    const p = argRaw(0);
    return @intCast(try Process.wait(p));
}

pub fn sbrk() !u64 {
    const n = argRaw(0);
    const addr = (try Process.current()).size;
    try Process.growCurrent(@intCast(n));
    return addr;
}

pub fn sleep() !u64 {
    const n: u32 = @intCast(argRaw(0));

    ticks_lock.acquire();
    defer ticks_lock.release();

    const ticks0 = ticks;
    while (ticks - ticks0 < n) {
        if ((try Process.current()).isKilled()) {
            return Error.ProcIsKilled;
        }
        Process.sleep(@intFromPtr(&ticks), &ticks_lock);
    }
    return 0;
}

pub fn kill() !u64 {
    const pid = argRaw(0);
    try Process.kill(@intCast(pid));
    return 0;
}

pub fn uptime() u64 {
    ticks_lock.acquire();
    defer ticks_lock.release();

    return ticks;
}
