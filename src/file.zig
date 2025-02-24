const Pipe = @import("pipe.zig");
const fs = @import("fs.zig");

pub const Inode = struct {
    dev: u32,
    inum: u32,
    ref: u32,
    // lock: SleepLock, TODO: impl
    valid: bool,

    type: u16,
    major: u16,
    minor: u16,
    nlink: u16,

    size: u32,
    addrs: [fs.n_direct + 1]u32,
};

type: enum { None, Pipe, Inode, Device },
ref: u32,
readable: bool,
writable: bool,
pipe: *Pipe,
inode: *Inode,
off: u32,
major: u16,
