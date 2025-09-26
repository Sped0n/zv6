const SleepLock = @import("../lock/SleepLock.zig");
const param = @import("../param.zig");
const assert = @import("../printf.zig").assert;
const printf = @import("../printf.zig").printf;
pub const Buffer = @import("Buffer.zig");
pub const DiskInode = @import("dinode.zig").DiskInode;
pub const File = @import("File.zig");
pub const Inode = @import("Inode.zig");
pub const InodeType = @import("dinode.zig").InodeType;
pub const log = @import("log.zig");
pub const OpenMode = @import("fcntl.zig").OpenMode;
pub const path = @import("path.zig");
pub const Pipe = @import("Pipe.zig");
pub const Stat = @import("stat.zig").Stat;
pub const SuperBlock = @import("SuperBlock.zig").SuperBlock;

pub const root_ino = 1; // root i-number
pub const block_size = 1024;

pub const magic = 0x10203040;

pub const n_direct = 12;
pub const n_indirect = block_size / @sizeOf(u32);
pub const max_file = n_direct + n_indirect;

pub const inodes_per_block = (block_size / @sizeOf(DiskInode));

pub const bitmap_bits_per_block = block_size * 8;

// Directory is a file containing a sequence of dirent structures.
pub const dir_size = 14;

pub const DirEntry = extern struct {
    inum: u16,
    name: [dir_size]u8,
};

pub var super_block: SuperBlock = undefined;

// File system implementation.  Five layers:
//   + Blocks: allocator for raw disk blocks.
//   + Log: crash recovery for multi-step updates.
//   + Files: inode allocator, reading, writing, metadata.
//   + Directories: inode with special contents (list of other inodes!)
//   + Names: paths like /usr/rtm/xv6/fs.c for convenient naming.
//
// This file contains the low-level file system manipulation
// routines.  The (higher-level) system call implementations
// are in sysfile.c.

//Init fs
pub fn init(dev: u32) void {
    super_block.init();
    super_block.read(dev);
    assert(super_block.magic == magic, @src());
    log.init(dev, &super_block);
}

// Blocks ----------------------------------------------------------------------

/// Zero a block
pub const block = struct {
    fn zero(dev: u32, blockno: u32) void {
        const buffer = Buffer.readFrom(dev, blockno);
        defer buffer.release();

        @memset(&buffer.data, 0);
        log.write(buffer);
    }

    /// Allocate a zeroed disk block, return null if out of disk space.
    /// Also mark the relevant bit in bitmap to 1.
    pub fn alloc(dev: u32) ?u32 {
        var buffer: *Buffer = undefined;
        var blockno: u32 = 0;
        while (blockno < super_block.size) : ({
            blockno += bitmap_bits_per_block;
        }) {
            buffer = Buffer.readFrom(
                dev,
                super_block.getBitmapBlockNo(blockno),
            );

            var bitmap_offset: u32 = 0;
            while (bitmap_offset < bitmap_bits_per_block and
                blockno + bitmap_offset < super_block.size) : ({
                bitmap_offset += 1;
            }) {
                const mask: u8 = @as(u8, 1) << @intCast(bitmap_offset % 8);
                const block_in_use = &buffer.data[bitmap_offset / 8];
                if (block_in_use.* & mask == 0) { // Is block free?
                    block_in_use.* |= mask; // Mark block in use.
                    log.write(buffer);
                    buffer.release();
                    zero(dev, blockno + bitmap_offset);
                    return blockno + bitmap_offset;
                }
            }

            buffer.release();
        }
        return null;
    }

    /// Free a disk block.
    /// Also mark the relevant bit in bitmap to 0.
    pub fn free(dev: u32, blockno: u32) void {
        const buffer = Buffer.readFrom(
            dev,
            super_block.getBitmapBlockNo(blockno),
        );
        defer buffer.release();

        const bitmap_offset = blockno % bitmap_bits_per_block;
        const mask: u8 = @as(u8, 1) << @intCast(bitmap_offset % 8);
        const block_in_use = &buffer.data[bitmap_offset / 8];
        assert(block_in_use.* & mask != 0, @src()); // Block should not be freed
        block_in_use.* &= ~mask; // Mark block free.
        log.write(buffer);
    }
};
