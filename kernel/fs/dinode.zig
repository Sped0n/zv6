const fs = @import("fs.zig");

pub const InodeType = enum(u16) {
    free = 0,
    directory = 1,
    file = 2,
    device = 3,
};

/// On-disk Inode structure
pub const DiskInode = extern struct {
    type: InodeType,
    major: u16,
    minor: u16,
    nlink: u16,
    size: u32,
    addrs: [fs.n_direct + 1]u32,
};
