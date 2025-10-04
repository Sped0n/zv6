const std = @import("std");
const mem = std.mem;

const assert = @import("../diag.zig").assert;
const SleepLock = @import("../lock/SleepLock.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const param = @import("../param.zig");
const Process = @import("../process/Process.zig");
const utils = @import("../utils.zig");
const fs = @import("fs.zig");

const log = std.log.scoped(.fs);

// Inodes ----------------------------------------------------------------------
//
// An inode describes a single unnamed file.
// The inode disk structure holds metadata: the file's type,
// its size, the number of links referring to it, and the
// list of blocks holding the file's content.
//
// The inodes are laid out sequentially on disk at block
// sb.inodestart. Each inode has a number, indicating its
// position on the disk.
//
// The kernel keeps a table of in-use inodes in memory
// to provide a place for synchronizing access
// to inodes used by multiple processes. The in-memory
// inodes include book-keeping information that is
// not stored on disk: ip->ref and ip->valid.
//
// An inode and its in-memory representation go through a
// sequence of states before they can be used by the
// rest of the file system code.
//
// * Allocation: an inode is allocated if its type (on disk)
//   is non-zero. ialloc() allocates, and iput() frees if
//   the reference and link counts have fallen to zero.
//
// * Referencing in table: an entry in the inode table
//   is free if ip->ref is zero. Otherwise ip->ref tracks
//   the number of in-memory pointers to the entry (open
//   files and current directories). iget() finds or
//   creates a table entry and increments its ref; iput()
//   decrements ref.
//
// * Valid: the information (type, size, &c) in an inode
//   table entry is only correct when ip->valid is 1.
//   ilock() reads the inode from
//   the disk and sets ip->valid, while iput() clears
//   ip->valid if ip->ref has fallen to zero.
//
// * Locked: file system code may only examine and modify
//   the information in an inode and its content if it
//   has first locked the inode.
//
// Thus a typical sequence is:
//   ip = iget(dev, inum)
//   ilock(ip)
//   ... examine and modify ip->xxx ...
//   iunlock(ip)
//   iput(ip)
//
// ilock() is separate from iget() so that system calls can
// get a long-term reference to an inode (as for an open file)
// and only lock it for short periods (e.g., in read()).
// The separation also helps avoid deadlock and races during
// pathname lookup. iget() increments ip->ref so that the inode
// stays in the table and pointers to it remain valid.
//
// Many internal file system functions expect the caller to
// have locked the inodes involved; this lets callers create
// multi-step atomic operations.
//
// The itable.lock spin-lock protects the allocation of itable
// entries. Since ip->ref indicates whether an entry is free,
// and ip->dev and ip->inum indicate which i-node an entry
// holds, one must hold itable.lock while using any of those fields.
//
// An ip->lock sleep-lock protects all ip-> fields other than ref,
// dev, and inum.  One must hold ip->lock in order to
// read or write that inode's ip->valid, ip->size, ip->type, &c.

dev: u32,
inum: u32,
ref: u32,
_lock: SleepLock,
valid: bool,

dinode: fs.DiskInode,

const Self = @This();

pub const Error = error{
    OffsetTooLarge,
    VMCopyFailed,
    BMapFailed,
    LenTooLarge,
    DirNamePresent,
    WriteSizeMismatch,
};

var inode_table = struct {
    lock: SpinLock,
    items: [param.n_inode]Self,

    const InodeTable = @This();

    pub fn get(self: *InodeTable, dev: u32, inum: u32) *Self {
        self.lock.acquire();
        defer self.lock.release();

        // Is the inode already in the table?
        var empty: ?*Self = null;
        for (&self.items) |*inode| {
            if (inode.ref > 0 and
                inode.dev == dev and
                inode.inum == inum)
            {
                inode.ref += 1;
                return inode;
            }
            if (empty == null and inode.ref == 0) empty = inode; // Remember empty slot.
        }

        // Recycle an inode entry.
        assert(empty != null);

        const inode = empty.?;
        inode.dev = dev;
        inode.inum = inum;
        inode.ref = 1;
        inode.valid = false;

        return inode;
    }
}{
    .lock = undefined,
    .items = [_]Self{Self{
        .dev = 0,
        .inum = 0,
        .ref = 0,
        ._lock = undefined,
        .valid = false,
        .dinode = fs.DiskInode{
            .type = .free,
            .major = 0,
            .minor = 0,
            .nlink = 0,
            .size = 0,
            .addrs = [_]u32{0} ** (fs.n_direct + 1),
        },
    }} ** param.n_inode,
};

pub fn init() void {
    inode_table.lock.init("itable");
    for (&inode_table.items) |*inode| {
        inode._lock.init("inode");
    }
    log.info("File system inode table initialized", .{});
}

pub fn get(dev: u32, inum: u32) *Self {
    return inode_table.get(dev, inum);
}

/// Allocate an inode on device dev.
/// Mark it as allocated by giving it type type.
/// Returns an unlocked but allocated and referenced inode,
/// or null if there is no free inode.
pub fn alloc(dev: u32, _type: fs.InodeType) ?*Self {
    for (1..fs.super_block.n_inodes) |inum| {
        const buffer = fs.Buffer.readFrom(
            dev,
            fs.super_block.getInodeBlockNo(@intCast(inum)),
        );
        defer buffer.release();

        const disk_inode = &@as(
            [*]fs.DiskInode,
            @ptrCast(&buffer.data),
        )[inum % fs.inodes_per_block];
        if (disk_inode.type == .free) { // a free node
            @memset(
                @as([*]u8, @ptrCast(disk_inode))[0..@sizeOf(fs.DiskInode)],
                0,
            );
            disk_inode.type = _type;
            fs.journal.write(buffer); // mark it allocated on the disk
            return get(dev, @intCast(inum));
        }
    }
    return null;
}

/// Copy a modified in-memory inode to disk.
/// Must be called after every change to an (*Inode)->xxx field
/// that lives on disk.
/// Caller must hold (*Inode)->lock.
pub fn update(self: *Self) void {
    const buffer = fs.Buffer.readFrom(
        self.dev,
        fs.super_block.getInodeBlockNo(self.inum),
    );
    defer buffer.release();

    const disk_inode = &@as(
        [*]fs.DiskInode,
        @ptrCast(&buffer.data),
    )[self.inum % fs.inodes_per_block];
    disk_inode.* = self.dinode;
    fs.journal.write(buffer);
}

/// Increment reference count for *Inode.
/// Returns *Inode to enable inode = inode.dup() idiom.
pub fn dup(self: *Self) *Self {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    self.ref += 1;
    return self;
}

/// Lock the given inode.
/// Reads the inode from disk if necessary.
pub fn lock(self: *Self) void {
    assert(self.ref > 0);

    self._lock.acquire();

    if (self.valid) return;

    {
        const buffer = fs.Buffer.readFrom(
            self.dev,
            fs.super_block.getInodeBlockNo(self.inum),
        );
        defer buffer.release();

        const disk_inode = &@as(
            [*]fs.DiskInode,
            @ptrCast(&buffer.data),
        )[self.inum % fs.inodes_per_block];
        (&self.dinode).* = disk_inode.*;
    }

    self.valid = true;
    assert(self.dinode.type != .free);
}

/// Unlock the given inode.
pub fn unlock(self: *Self) void {
    assert(self._lock.holding() and self.ref > 0);

    self._lock.release();
}

/// Drop a reference to an in-memory inode.
/// If that was the last reference, the inode table entry can
/// be recycled.
/// If that was the last reference and the inode has no links
/// to it, free the inode (and its content) on disk.
/// All calls to put() must be inside a transaction in
/// case it has to free the inode.
pub fn put(self: *Self) void {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    if (self.ref == 1 and self.valid and self.dinode.nlink == 0) {
        // inode has no links and no other references: truncate and free.

        // ip->ref == 1 means no other process can have ip locked,
        // so this self._lock.acquire() won't block (or deadlock).
        self._lock.acquire();
        inode_table.lock.release();
        defer {
            self._lock.release();
            inode_table.lock.acquire();
        }

        self.truncate();
        self.dinode.type = .free;
        self.update();
        self.valid = false;
    }

    self.ref -= 1;
}

/// Common idiom: unlock, then put
pub fn unlockPut(self: *Self) void {
    self.unlock();
    self.put();
}

// Inode content ---------------------------------------------------------------
//
// The content (data) associated with each inode is stored
// in blocks on the disk. The first NDIRECT block numbers
// are listed in ip->addrs[].  The next NINDIRECT blocks are
// listed in block ip->addrs[NDIRECT].

/// Return the disk block address of the nth block in inode ip.
/// If there is no such block, bmap allocates one.
/// returns null if out of disk space.
fn bmap(self: *Self, blockno: u32) ?u32 {
    var addr: u32 = 0;
    var _blockno = blockno;

    if (_blockno < fs.n_direct) {
        addr = self.dinode.addrs[_blockno];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            self.dinode.addrs[_blockno] = addr;
        }
        return addr;
    }

    _blockno -= fs.n_direct;

    if (_blockno < fs.n_indirect) {
        // Load indirect block, allocating if necessary.
        addr = self.dinode.addrs[fs.n_direct];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            self.dinode.addrs[fs.n_direct] = addr;
        }

        const buffer = fs.Buffer.readFrom(self.dev, addr);
        defer buffer.release();

        const buffer_data: [*]u32 = @ptrCast(&buffer.data);

        addr = buffer_data[_blockno];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            buffer_data[_blockno] = addr;
            fs.journal.write(buffer);
        }

        return addr;
    }

    // out of range
    unreachable;
}

// Truncate inode (discard contents).
// Caller must hold ip->lock.
pub fn truncate(self: *Self) void {
    for (0..fs.n_direct) |i| {
        if (self.dinode.addrs[i] != 0) {
            fs.block.free(self.dev, self.dinode.addrs[i]);
            self.dinode.addrs[i] = 0;
        }
    }

    if (self.dinode.addrs[fs.n_direct] != 0) {
        {
            const buffer = fs.Buffer.readFrom(
                self.dev,
                self.dinode.addrs[fs.n_direct],
            );
            defer buffer.release();

            const buffer_data: [*]u32 = @ptrCast(&buffer.data);
            for (0..fs.n_indirect) |i| {
                if (buffer_data[i] != 0) fs.block.free(
                    self.dev,
                    buffer_data[i],
                );
            }
        }
        fs.block.free(self.dev, self.dinode.addrs[fs.n_direct]);
        self.dinode.addrs[fs.n_direct] = 0;
    }

    self.dinode.size = 0;
    self.update();
}

/// Copy stat infomation from inode
/// Caller must hold self._lock
pub fn statCopyTo(self: *Self, stat: *fs.Stat) void {
    stat.dev = self.dev;
    stat.inum = self.inum;
    stat.type = self.dinode.type;
    stat.nlink = self.dinode.nlink;
    stat.size = @intCast(self.dinode.size);
}

/// Read data from inode.
/// Caller must hold self->lock.
/// If is_user_dst==true, then dst_addr is a user virtual address;
/// otherwise, dst_addr is a kernel address.
pub fn read(
    self: *Self,
    is_user_dst: bool,
    dst_addr: u64,
    offset: u32,
    len: u32,
) !u32 {
    var total = len;

    if (offset > self.dinode.size or
        offset + len < offset)
        return 0;
    if (offset + len > self.dinode.size)
        total = self.dinode.size - offset;

    var n_read: u32 = 0;
    var dst_anchor = dst_addr;
    var offset_anchor = offset;
    var step: u32 = 0;

    while (n_read < total) : ({
        n_read += step;
        dst_anchor += step;
        offset_anchor += step;
    }) {
        const blockno = self.bmap(
            offset_anchor / fs.block_size,
        ) orelse return Error.BMapFailed;

        const buffer = fs.Buffer.readFrom(self.dev, blockno);
        defer buffer.release();

        const modded_offset_anchor = offset_anchor % fs.block_size;
        step = @min(
            total - n_read,
            fs.block_size - modded_offset_anchor,
        );
        try Process.eitherCopyOut(
            is_user_dst,
            dst_anchor,
            buffer.data[modded_offset_anchor..].ptr,
            step,
        );
    }

    return n_read;
}

/// Write data to inode.
/// Caller must hold ip->lock.
/// If user_src==1, then src is a user virtual address;
/// otherwise, src is a kernel address.
/// Returns the number of bytes successfully written.
/// If the return value is less than the requested n,
/// there was an error of some kind.
pub fn write(
    self: *Self,
    is_user_src: bool,
    src_addr: u64,
    offset: u32,
    len: u32,
) !u32 {
    if (offset > self.dinode.size or offset + len < offset)
        return Error.OffsetTooLarge;
    if (offset + len > fs.max_file * fs.block_size)
        return Error.LenTooLarge;

    // write the i-node back to disk even if the size didn't change
    // because the loop above might have called bmap() and added a new
    // block to self.dinode.addrs[].
    defer self.update();

    var n_write: u32 = 0;
    var src_anchor = src_addr;
    var offset_anchor = offset;
    var step: u32 = 0;

    defer self.dinode.size = @max(offset_anchor, self.dinode.size);

    while (n_write < len) : ({
        n_write += step;
        src_anchor += step;
        offset_anchor += step;
    }) {
        const blockno = self.bmap(
            offset_anchor / fs.block_size,
        ) orelse return Error.BMapFailed;

        const buffer = fs.Buffer.readFrom(self.dev, blockno);
        defer buffer.release();

        step = @min(
            len - n_write,
            fs.block_size - offset_anchor % fs.block_size,
        );
        try Process.eitherCopyIn(
            buffer.data[offset_anchor % fs.block_size ..].ptr,
            is_user_src,
            src_anchor,
            step,
        );
        fs.journal.write(buffer);
    }

    return n_write;
}

// Directories -----------------------------------------------------------------

/// Look for a directory entry in a directory.
/// If found, set *poff to byte offset of entry.
pub fn dirLookUp(self: *Self, name: []const u8, offset_ptr: ?*u32) ?*Self {
    assert(self.dinode.type == .directory);

    var offset: u32 = 0;
    var dir_entry: fs.DirEntry = undefined;
    const step = @sizeOf(fs.DirEntry);

    while (offset < self.dinode.size) : (offset += step) {
        assert(
            self.read(
                false,
                @intFromPtr(&dir_entry),
                offset,
                step,
            ) catch unreachable == step,
        );

        if (dir_entry.inum == 0) continue;

        if (mem.eql(u8, name, mem.sliceTo(&dir_entry.name, 0))) {
            if (offset_ptr) |p| p.* = offset;
            return get(self.dev, dir_entry.inum);
        }
    }

    return null;
}

// Write a new directory entry (name, inum) into the directory dp.
// Returns 0 on success, -1 on failure (e.g. out of disk blocks).
pub fn dirLink(self: *Self, name: []const u8, inum: u32) !void {
    // Check that name is not present.
    if (self.dirLookUp(name, null)) |inode| {
        inode.put();
        return Error.DirNamePresent;
    }

    // Look for an empty dir_entry.
    var offset: u32 = 0;
    var dir_entry: fs.DirEntry = undefined;
    const step: u32 = @sizeOf(fs.DirEntry);
    while (offset < self.dinode.size) : (offset += step) {
        assert(
            self.read(
                false,
                @intFromPtr(&dir_entry),
                offset,
                step,
            ) catch unreachable == step,
        );

        if (dir_entry.inum == 0) break;
    }

    utils.safeStrCopy(&dir_entry.name, name);
    dir_entry.inum = @intCast(inum);

    const write_size = try self.write(
        false,
        @intFromPtr(&dir_entry),
        offset,
        step,
    );
    if (write_size != step) return Error.WriteSizeMismatch;
}
