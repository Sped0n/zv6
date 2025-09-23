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

var buffer_cache = struct {
    lock: SpinLock,
    buffers: [param.n_buf]Self,

    /// Linked list of all buffers, through prev/next.
    /// Sorted by how recently the buffer was used.
    /// head.next is most recent, head.prev is least.
    head: Self,
}{
    .lock = undefined,
    .buffers = [_]Self{Self{
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
    buffer_cache.lock.init("bcache");

    // Create linked list of buffers
    buffer_cache.head.prev = &buffer_cache.head;
    buffer_cache.head.next = &buffer_cache.head;
    for (&buffer_cache.buffers) |*buffer| {
        buffer.next = buffer_cache.head.next;
        buffer.prev = &buffer_cache.head;
        buffer.lock.init("buffer");
        buffer_cache.head.next.prev = buffer;
        buffer_cache.head.next = buffer;
    }
}

/// Look through buffer cache for block on device dev.
/// If not found, allocate a buffer.
/// In either case, return locked buffer.
fn get(dev: u32, blockno: u32) *Self {
    var buffer: *Self = undefined;
    defer buffer.lock.acquire();

    buffer_cache.lock.acquire();
    defer buffer_cache.lock.release();

    // Is the block already cached?
    buffer = buffer_cache.head.next;
    while (buffer != &buffer_cache.head) : (buffer = buffer.next) {
        if (buffer.dev != dev or buffer.blockno != blockno) continue;

        buffer.refcnt += 1;
        return buffer;
    }

    // Not cached.
    // Recycle the least recently used (LRU) unused buffer.
    buffer = buffer_cache.head.prev;
    while (buffer != &buffer_cache.head) : (buffer = buffer.prev) {
        if (buffer.refcnt != 0) continue;

        buffer.dev = dev;
        buffer.blockno = blockno;
        buffer.valid = false;
        buffer.refcnt = 1;
        return buffer;
    }

    panic(@src(), "no buf available", .{});
}

/// Return a locked buf with the content of the indicated block.
pub fn readFrom(dev: u32, blockno: u32) *Self {
    var buffer = get(dev, blockno);
    if (!buffer.valid) {
        virtio_disk.diskReadWrite(buffer, false);
        buffer.valid = true;
    }
    return buffer;
}

/// Write buf's contents to disk. Must be locked.
pub fn writeBack(self: *Self) void {
    if (!self.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );
    virtio_disk.diskReadWrite(self, true);
}

/// Release a locked buffer.
/// Move to the head of the most recently-used list.
pub fn release(self: *Self) void {
    if (!self.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );

    self.lock.release();

    buffer_cache.lock.acquire();
    defer buffer_cache.lock.release();

    self.refcnt -= 1;
    if (self.refcnt == 0) {
        // no one is waiting for it.
        self.next.prev = self.prev;
        self.prev.next = self.next;
        self.next = buffer_cache.head.next;
        self.prev = &buffer_cache.head;
        buffer_cache.head.next.prev = self;
        buffer_cache.head.next = self;
    }
}

pub fn pin(self: *Self) void {
    buffer_cache.lock.acquire();
    defer buffer_cache.lock.release();

    self.refcnt += 1;
}

pub fn unPin(self: *Self) void {
    buffer_cache.lock.acquire();
    defer buffer_cache.lock.release();

    self.refcnt -= 1;
}
