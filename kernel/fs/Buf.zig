const SleepLock = @import("../lock/SleepLock.zig");
const fs = @import("fs.zig");
const virtio_disk = @import("../driver/virtio_disk.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;

valid: bool,
owned_by_disk: bool,
dev: u32,
blockno: u32,
lock: SleepLock,
refcnt: u32,
prev: *Self,
next: *Self,
data: [fs.block_size]u8,

const Self = @This();

var bcache = struct {
    lock: SpinLock,
    buf: [param.n_buf]Self,

    ///Linked list of all buffers, through prev/next.
    ///Sorted by how recently the buffer was used.
    ///head.next is most recent, head.prev is least.
    head: Self,
}{
    .lock = undefined,
    .buf = [_]Self{Self{
        .valid = false,
        .owned_by_disk = false,
        .dev = 0,
        .blockno = 0,
        .lock = undefined,
        .refcnt = 0,
        .prev = undefined,
        .next = undefined,
        .data = [_]u8{0} ** fs.block_size,
    }} ** param.n_buf,
    .head = Self{
        .valid = false,
        .owned_by_disk = false,
        .dev = 0,
        .blockno = 0,
        .lock = undefined,
        .refcnt = 0,
        .prev = undefined,
        .next = undefined,
        .data = [_]u8{0} ** fs.block_size,
    },
};

pub fn init() void {
    bcache.lock.init("bcache");

    // Create linked list of buffers
    bcache.head.prev = &bcache.head;
    bcache.head.next = &bcache.head;
    for (0..param.n_buf) |i| {
        const b = &bcache.buf[i];
        b.next = bcache.head.next;
        b.prev = &bcache.head;
        b.lock.init("buffer");
        bcache.head.next.prev = b;
        bcache.head.next = b;
    }
}

///Look through buffer cache for block on device dev.
///If not found, allocate a buffer.
///In either case, return locked buffer.
fn get(dev: u32, blockno: u32) *Self {
    var buf: *Self = undefined;

    bcache.lock.acquire();
    defer {
        bcache.lock.release();
        buf.lock.acquire();
    }

    // Is the block already cached?
    buf = bcache.head.next;
    while (buf != &bcache.head) : (buf = buf.next) {
        if (!(buf.dev == dev and buf.blockno == blockno)) continue;

        buf.refcnt += 1;
        return buf;
    }

    // Not cached.
    // Recycle the least recently used (LRU) unused buffer.
    buf = bcache.head.prev;
    while (buf != &bcache.head) : (buf = buf.prev) {
        if (buf.refcnt != 0) continue;

        buf.dev = dev;
        buf.blockno = blockno;
        buf.valid = false;
        buf.refcnt = 1;
        return buf;
    }

    panic(@src(), "no buf available", .{});
}

///Return a locked buf with the content of the indicated block.
pub fn readFrom(dev: u32, blockno: u32) *Self {
    var buf = get(dev, blockno);
    if (!buf.valid) {
        virtio_disk.diskReadWrite(buf, false);
        buf.valid = true;
    }
    return buf;
}

///Write buf's contents to disk. Must be locked.
pub fn writeBack(self: *Self) void {
    if (!self.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );
    virtio_disk.diskReadWrite(self, true);
}

///Release a locked buffer.
///Move to the head of the most recently-used list.
pub fn release(self: *Self) void {
    if (!self.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );

    self.lock.release();

    bcache.lock.acquire();
    defer bcache.lock.release();

    self.refcnt -= 1;
    if (self.refcnt == 0) {
        // no one is waiting for it.
        self.next.prev = self.prev;
        self.prev.next = self.next;
        self.next = bcache.head.next;
        self.prev = &bcache.head;
        bcache.head.next.prev = self;
        bcache.head.next = self;
    }
}

pub fn pin(self: *Self) void {
    bcache.lock.acquire();
    defer bcache.lock.release();

    self.refcnt += 1;
}

pub fn unPin(self: *Self) void {
    bcache.lock.acquire();
    defer bcache.lock.release();

    self.refcnt -= 1;
}
