const memMove = @import("../misc.zig").memMove;
const bio = @import("bio.zig");
const fs = @import("fs.zig");

///Disk layout:
///[ boot block | super block | log | inode blocks | free bit map | data blocks]
///
///mkfs computes the super block and builds an initial file system. The
///super block describes the disk layout:
pub const SuperBlock = extern struct {
    magic: u32, // Must be fs_magic
    size: u32, // Size of file system image (blocks)
    n_blocks: u32, // Number of data blocks
    n_inodes: u32, // Number of inodes
    n_log: u32, // Number of log blocks
    log_start: u32, // Block number of first log block
    inode_start: u32, // Block number of first inode block
    bitmap_start: u32, // Block number of first free map block

    const Self = @This();

    pub fn init(self: *Self) void {
        self.magic = 0;
        self.size = 0;
        self.n_blocks = 0;
        self.n_inodes = 0;
        self.n_log = 0;
        self.log_start = 0;
        self.inode_start = 0;
        self.bitmap_start = 0;
    }

    pub fn read(self: *Self, dev: u32) void {
        const buf_ptr = bio.read(dev, 1);
        memMove(@as([*]u8, self), buf_ptr.data, @sizeOf(self.*));
    }

    pub inline fn getBitmapBlockNo(self: *Self, blockno: u32) u32 {
        return blockno / fs.bitmap_bits_per_block + self.bitmap_start;
    }

    pub inline fn getInodeBlockNo(self: *Self, inum: u32) u32 {
        return inum / fs.inodes_per_block + self.inode_start;
    }
};

pub var super_block: SuperBlock = undefined;
