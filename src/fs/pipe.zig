const SpinLock = @import("../lock/SpinLock.zig");

const pipe_size = 512;

lock: SpinLock,
data: [pipe_size]u8,
nread: u32,
nwrite: u32,
readopen: bool,
writeopen: bool,
