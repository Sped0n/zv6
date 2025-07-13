const SleepLock = @import("../lock/SleepLock.zig");
const param = @import("../param.zig");
const assert = @import("../printf.zig").assert;
const printf = @import("../printf.zig").printf;
const Buf = @import("Buf.zig");
const DiskInode = @import("dinode.zig").DiskInode;
const log = @import("log.zig");
const SuperBlock = @import("SuperBlock.zig").SuperBlock;

pub const root_ino = 1; // root i-number
pub const block_size = 1024; // block size

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

///Zero a block
pub const block = struct {
    fn zero(dev: u32, blockno: u32) void {
        const buf = Buf.readFrom(dev, blockno);
        defer buf.release();

        @memset(&buf.data, 0);
        log.write(buf);
    }

    ///Allocate a zeroed disk block, return null if out of disk space.
    ///Also mark the relevant bit in bitmap to 1.
    pub fn alloc(dev: u32) ?u32 {
        var buf: *Buf = undefined;
        var blockno: u32 = 0;
        while (blockno < super_block.size) : ({
            blockno += bitmap_bits_per_block;
        }) {
            buf = Buf.readFrom(
                dev,
                super_block.getBitmapBlockNo(blockno),
            );

            var bitmap_offset: u32 = 0;
            while (bitmap_offset < bitmap_bits_per_block and
                blockno + bitmap_offset < super_block.size) : ({
                bitmap_offset += 1;
            }) {
                const mask: u8 = @as(u8, 1) << @intCast(bitmap_offset % 8);
                const block_in_use_ptr = &buf.data[bitmap_offset / 8];
                if (block_in_use_ptr.* & mask == 0) { // Is block free?
                    block_in_use_ptr.* |= mask; // Mark block in use.
                    log.write(buf);
                    buf.release();
                    zero(dev, blockno + bitmap_offset);
                    return blockno + bitmap_offset;
                }
            }

            buf.release();
        }
        return null;
    }

    ///Free a disk block.
    ///Also mark the relevant bit in bitmap to 0.
    pub fn free(dev: u32, blockno: u32) void {
        const buf = Buf.readFrom(
            dev,
            super_block.getBitmapBlockNo(blockno),
        );
        defer buf.release();

        const bitmap_offset = blockno % bitmap_bits_per_block;
        const mask: u8 = @as(u8, 1) << @intCast(bitmap_offset % 8);
        const block_in_use_ptr = &buf.data[bitmap_offset / 8];
        assert(block_in_use_ptr.* & mask != 0, @src());
        block_in_use_ptr.* &= ~mask;
        log.write(buf);
    }
};
