const Process = @import("../process/Process.zig");
const trap = @import("../trap.zig");
const syscall = @import("syscall.zig");

pub const Error = error{
    ProcIsKilled,
    ShrinkGreaterThanHeapSize,
};

pub fn exit() u64 {
    const exit_status: i32 = syscall.argument.as(i32, 0);
    Process.exit(exit_status);
    return 0;
}

pub fn getPid() !u64 {
    return @intCast((try Process.current()).pid);
}

pub fn fork() !u64 {
    return @intCast(try Process.fork());
}

pub fn wait() !u64 {
    const addr: u64 = syscall.argument.as(u64, 0);
    return @intCast(try Process.wait(addr));
}

pub fn sbrk() !u64 {
    const delta: i32 = syscall.argument.as(i32, 0);
    const addr = (try Process.current()).size;
    if (delta < 0) {
        const shrink_amount: u64 = @abs(delta);
        if (shrink_amount > addr) {
            return error.ShrinkGreaterThanHeapSize;
        }
    }
    try Process.growCurrent(delta);
    return addr;
}

pub fn sleep() !u64 {
    const sleep_ticks: u32 = syscall.argument.as(u32, 0);

    trap.ticks_lock.acquire();
    defer trap.ticks_lock.release();

    const ticks0 = trap.ticks;
    while (trap.ticks - ticks0 < sleep_ticks) {
        if ((try Process.current()).isKilled()) {
            return Error.ProcIsKilled;
        }
        Process.sleep(@intFromPtr(&trap.ticks), &trap.ticks_lock);
    }
    return 0;
}

pub fn kill() !u64 {
    const pid: u32 = syscall.argument.as(u32, 0);
    try Process.kill(pid);
    return 0;
}

pub fn uptime() u64 {
    trap.ticks_lock.acquire();
    defer trap.ticks_lock.release();

    return trap.ticks;
}
