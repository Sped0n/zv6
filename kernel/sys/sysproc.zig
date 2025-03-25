const Process = @import("../process/Process.zig");
const trap = @import("../trap.zig");
const argI32 = @import("syscall.zig").argI32;
const argRaw = @import("syscall.zig").argRaw;
const argU32 = @import("syscall.zig").argU32;

pub const Error = error{
    ProcIsKilled,
};

pub fn exit() u64 {
    const n = argI32(0);
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
    const n = argI32(0);
    const addr = (try Process.current()).size;
    try Process.growCurrent(n);
    return addr;
}

pub fn sleep() !u64 {
    const n = argU32(0);

    trap.ticks_lock.acquire();
    defer trap.ticks_lock.release();

    const ticks0 = trap.ticks;
    while (trap.ticks - ticks0 < n) {
        if ((try Process.current()).isKilled()) {
            return Error.ProcIsKilled;
        }
        Process.sleep(@intFromPtr(&trap.ticks), &trap.ticks_lock);
    }
    return 0;
}

pub fn kill() !u64 {
    const pid = argU32(0);
    try Process.kill(pid);
    return 0;
}

pub fn uptime() u64 {
    trap.ticks_lock.acquire();
    defer trap.ticks_lock.release();

    return trap.ticks;
}
