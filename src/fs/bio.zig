const virtio_disk = @import("../driver/virtio_disk.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;
const Buf = @import("Buf.zig");

var bcache = struct {
    lock: SpinLock,
    buf: [param.n_buf]Buf,

    ///Linked list of all buffers, through prev/next.
    ///Sorted by how recently the buffer was used.
    ///head.next is most recent, head.prev is least.
    head: Buf,
}{
    .lock = undefined,
    .buf = undefined,
    .head = undefined,
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
fn get(dev: u32, blockno: u32) *Buf {
    var buf: *Buf = undefined;

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
pub fn read(dev: u32, blockno: u32) *Buf {
    var buf = get(dev, blockno);
    if (!buf.valid) {
        virtio_disk.diskReadWrite(buf, false);
        buf.valid = true;
    }
    return buf;
}

///Write buf's contents to disk. Must be locked.
pub fn write(buf_ptr: *Buf) void {
    if (!buf_ptr.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );
    virtio_disk.diskReadWrite(buf_ptr, true);
}

///Release a locked buffer.
///Move to the head of the most recently-used list.
pub fn release(buf_ptr: *Buf) void {
    if (!buf_ptr.lock.holding()) panic(
        @src(),
        "buf is not locked",
        .{},
    );

    buf_ptr.lock.release();

    bcache.lock.acquire();
    defer bcache.lock.release();

    buf_ptr.refcnt -= 1;
    if (buf_ptr.refcnt == 0) {
        // no one is waiting for it.
        buf_ptr.next.prev = buf_ptr.prev;
        buf_ptr.prev.next = buf_ptr.next;
        buf_ptr.next = bcache.head.next;
        buf_ptr.prev = &bcache.head;
        bcache.head.next.prev = buf_ptr;
        bcache.head.next = buf_ptr;
    }
}

pub fn pin(buf_ptr: *Buf) void {
    bcache.lock.acquire();
    defer bcache.lock.release();

    buf_ptr.refcnt += 1;
}

pub fn unPin(buf_ptr: *Buf) void {
    bcache.lock.acquire();
    defer bcache.lock.release();

    buf_ptr.refcnt -= 1;
}
