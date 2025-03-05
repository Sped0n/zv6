const Spinlock = @import("../lock/spinlock.zig");

const pipe_size = 512;

lock: Spinlock,
data: [pipe_size]u8,
nread: u32,
nwrite: u32,
readopen: bool,
writeopen: bool,
