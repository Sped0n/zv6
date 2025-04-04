const mem = @import("std").mem;

const SleepLock = @import("../lock/SleepLock.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const misc = @import("../misc.zig");
const param = @import("../param.zig");
const printf = @import("../printf.zig").printf;
const assert = @import("../printf.zig").assert;
const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const DiskInode = @import("dinode.zig").DiskInode;
const Buf = @import("Buf.zig");
const fs = @import("fs.zig");
const DirEntry = fs.DirEntry;
const InodeType = @import("dinode.zig").InodeType;
const log = @import("log.zig");
const Stat = @import("stat.zig").Stat;

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

dinode: DiskInode,

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
        var inode: *Self = undefined;
        for (0..param.n_inode) |i| {
            inode = &self.items[i];
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
        assert(empty != null, @src());

        inode = empty.?;
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
        .dinode = DiskInode{
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
    for (0..param.n_inode) |i| {
        inode_table.items[i]._lock.init("inode");
    }
}

pub fn get(dev: u32, inum: u32) *Self {
    return inode_table.get(dev, inum);
}

///Allocate an inode on device dev.
///Mark it as allocated by giving it type type.
///Returns an unlocked but allocated and referenced inode,
///or null if there is no free inode.
pub fn alloc(dev: u32, _type: InodeType) ?*Self {
    for (1..fs.super_block.n_inodes) |inum| {
        const buf = Buf.readFrom(
            dev,
            fs.super_block.getInodeBlockNo(@intCast(inum)),
        );
        defer buf.release();

        const disk_inode_ptr = &@as(
            [*]align(1) DiskInode,
            @ptrCast(&buf.data),
        )[inum % fs.inodes_per_block];
        if (disk_inode_ptr.type == .free) { // a free node
            @memset(@as([*]u8, @ptrCast(disk_inode_ptr))[0..@sizeOf(DiskInode)], 0);
            disk_inode_ptr.type = _type;
            log.write(buf); // mark it allocated on the disk
            return get(dev, @intCast(inum));
        }
    }
    printf("Inode.alloc: no inodes\n", .{});
    return null;
}

///Copy a modified in-memory inode to disk.
///Must be called after every change to an (*Inode)->xxx field
///that lives on disk.
///Caller must hold (*Inode)->lock.
pub fn update(self: *Self) void {
    const buf = Buf.readFrom(
        self.dev,
        fs.super_block.getInodeBlockNo(self.inum),
    );
    defer buf.release();

    const disk_inode_ptr = &@as(
        [*]align(1) DiskInode,
        @ptrCast(&buf.data),
    )[self.inum % fs.inodes_per_block];
    disk_inode_ptr.* = self.dinode;
    log.write(buf);
}

///Increment reference count for *Inode.
///Returns *Inode to enable inode_ptr = inode_ptr.dup() idiom.
pub fn dup(self: *Self) *Self {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    self.ref += 1;
    return self;
}

///Lock the given inode.
///Reads the inode from disk if necessary.
pub fn lock(self: *Self) void {
    assert(self.ref > 0, @src());

    self._lock.acquire();

    if (self.valid) return;

    {
        const buf = Buf.readFrom(
            self.dev,
            fs.super_block.getInodeBlockNo(self.inum),
        );
        defer buf.release();

        const disk_inode_ptr = &@as(
            [*]align(1) DiskInode,
            @ptrCast(&buf.data),
        )[self.inum % fs.inodes_per_block];
        (&self.dinode).* = disk_inode_ptr.*;
    }

    self.valid = true;
    assert(self.dinode.type != .free, @src());
}

///Unlock the given inode.
pub fn unlock(self: *Self) void {
    assert(self._lock.holding() and self.ref > 0, @src());

    self._lock.release();
}

///Drop a reference to an in-memory inode.
///If that was the last reference, the inode table entry can
///be recycled.
///If that was the last reference and the inode has no links
///to it, free the inode (and its content) on disk.
///All calls to put() must be inside a transaction in
///case it has to free the inode.
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

///Common idiom: unlock, then put
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

///Return the disk block address of the nth block in inode ip.
///If there is no such block, bmap allocates one.
///returns null if out of disk space.
fn bmap(self: *Self, blockno: u32) ?u32 {
    var addr: u32 = 0;
    var local_blockno = blockno;

    if (local_blockno < fs.n_direct) {
        addr = self.dinode.addrs[local_blockno];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            self.dinode.addrs[local_blockno] = addr;
        }
        return addr;
    }

    local_blockno -= fs.n_direct;

    if (local_blockno < fs.n_indirect) {
        // Load indirect block, allocating if necessary.
        addr = self.dinode.addrs[fs.n_direct];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            self.dinode.addrs[fs.n_direct] = addr;
        }

        const buf = Buf.readFrom(self.dev, addr);
        defer buf.release();

        const buf_data: [*]align(1) u32 = @ptrCast(&buf.data);

        addr = buf_data[local_blockno];
        if (addr == 0) {
            addr = fs.block.alloc(self.dev) orelse return null;
            buf_data[local_blockno] = addr;
            log.write(buf);
        }

        return addr;
    }

    panic(@src(), "out of range", .{});
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
            const buf = Buf.readFrom(
                self.dev,
                self.dinode.addrs[fs.n_direct],
            );
            defer buf.release();

            const buf_data: [*]align(1) u32 = @ptrCast(&buf.data);
            for (0..fs.n_indirect) |i| {
                if (buf_data[i] != 0) fs.block.free(
                    self.dev,
                    self.dinode.addrs[fs.n_direct],
                );
            }
        }
        fs.block.free(self.dev, self.dinode.addrs[fs.n_direct]);
        self.dinode.addrs[fs.n_direct] = 0;
    }

    self.dinode.size = 0;
    self.update();
}

///Copy stat infomation from inode
///Caller must hold self._lock
pub fn stat(self: *Self, stat_ptr: *Stat) void {
    stat_ptr.dev = self.dev;
    stat_ptr.inum = self.inum;
    stat_ptr.type = self.dinode.type;
    stat_ptr.nlink = self.dinode.nlink;
    stat_ptr.size = @intCast(self.dinode.size);
}

///Read data from inode.
///Caller must hold self->lock.
///If is_user_dst==true, then dst_addr is a user virtual address;
///otherwise, dst_addr is a kernel address.
pub fn read(
    self: *Self,
    is_user_dst: bool,
    dst_addr: u64,
    offset: u32,
    len: u32,
) !u32 {
    var local_len = len;
    var local_offset = offset;

    if (local_offset > self.dinode.size or
        local_offset + local_len < local_offset)
        return Error.OffsetTooLarge;
    if (local_offset + local_len > self.dinode.size)
        local_len = self.dinode.size - offset;

    var total: u32 = 0;
    var read_len: u32 = 0;
    var local_dst_addr = dst_addr;

    while (total < local_len) : ({
        total += read_len;
        local_offset += read_len;
        local_dst_addr += read_len;
    }) {
        const blockno = self.bmap(
            local_offset / fs.block_size,
        ) orelse return Error.BMapFailed;

        const buf = Buf.readFrom(self.dev, blockno);
        defer buf.release();

        const modded_local_offset = local_offset % fs.block_size;
        read_len = @min(
            local_len - total,
            fs.block_size - modded_local_offset,
        );
        try Process.eitherCopyOut(
            is_user_dst,
            local_dst_addr,
            buf.data[modded_local_offset..].ptr,
            read_len,
        );
    }

    return total;
}

///Write data to inode.
///Caller must hold ip->lock.
///If user_src==1, then src is a user virtual address;
///otherwise, src is a kernel address.
///Returns the number of bytes successfully written.
///If the return value is less than the requested n,
///there was an error of some kind.
pub fn write(
    self: *Self,
    is_user_src: bool,
    src_addr: u64,
    offset: u32,
    len: u32,
) !u32 {
    var local_offset = offset;

    if (local_offset > self.dinode.size or local_offset + len < local_offset)
        return Error.OffsetTooLarge;
    if (local_offset + len > fs.max_file * fs.block_size)
        return Error.LenTooLarge;

    var total: u32 = 0;
    var write_len: u32 = 0;
    var local_src_addr = src_addr;
    var _error: ?anyerror = null;

    while (total < len) : ({
        total += write_len;
        local_offset += write_len;
        local_src_addr += write_len;
    }) {
        const blockno = self.bmap(
            local_offset / fs.block_size,
        ) orelse {
            _error = Error.BMapFailed;
            break;
        };

        const buf = Buf.readFrom(self.dev, blockno);
        defer buf.release();

        write_len = @min(
            len - total,
            fs.block_size - local_offset % fs.block_size,
        );
        Process.eitherCopyIn(
            buf.data[local_offset % fs.block_size ..].ptr,
            is_user_src,
            local_src_addr,
            write_len,
        ) catch |e| {
            _error = e;
            break;
        };
        log.write(buf);
    }

    if (offset > self.dinode.size) self.dinode.size = offset;

    // write the i-node back to disk even if the size didn't change
    // because the loop above might have called bmap() and added a new
    // block to self.dinode.addrs[].
    self.update();

    if (_error) |e| {
        return e;
    } else {
        return total;
    }
}

// Directories -----------------------------------------------------------------

///Look for a directory entry in a directory.
///If found, set *poff to byte offset of entry.
pub fn dirLookUp(self: *Self, name: []const u8, offset_ptr: ?*u32) ?*Self {
    assert(self.dinode.type == .directory, @src());

    var offset: u32 = 0;
    var dir_entry: DirEntry = undefined;
    const step = @sizeOf(DirEntry);

    while (offset < self.dinode.size) : (offset += step) {
        assert(
            self.read(
                false,
                @intFromPtr(&dir_entry),
                offset,
                step,
            ) catch |e| panic(
                @src(),
                "read failed with {s}",
                .{@errorName(e)},
            ) == step,
            @src(),
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
    if (self.dirLookUp(name, null)) |inode_ptr| {
        inode_ptr.put();
        return Error.DirNamePresent;
    }

    // Look for an empty dir_entry.
    var offset: u32 = 0;
    var dir_entry: DirEntry = undefined;
    const step: u32 = @sizeOf(DirEntry);
    while (offset < self.dinode.size) : (offset += step) {
        assert(
            self.read(
                false,
                @intFromPtr(&dir_entry),
                offset,
                step,
            ) catch |e| {
                panic(
                    @src(),
                    "dirlink read failed with {s}",
                    .{@errorName(e)},
                );
            } == step,
            @src(),
        );

        if (dir_entry.inum == 0) break;
    }

    misc.safeStrCopy(&dir_entry.name, name);
    dir_entry.inum = @intCast(inum);

    const write_size = try self.write(
        false,
        @intFromPtr(&dir_entry),
        offset,
        step,
    );
    if (write_size != step) return Error.WriteSizeMismatch;
}
