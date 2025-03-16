const InodeType = @import("dinode.zig").InodeType;

pub const Stat = extern struct {
    dev: u32,
    inum: u32,
    type: InodeType,
    nlink: u16,
    size: u64,
};
