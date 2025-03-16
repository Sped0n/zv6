const SleepLock = @import("../lock/SleepLock.zig");
const fs = @import("fs.zig");

valid: bool,
owned_by_disk: bool,
dev: u32,
blockno: u32,
lock: SleepLock,
refcnt: u32,
prev: *Self,
next: *Self,
data: [fs.block_size]u8,

const Self = @This();
