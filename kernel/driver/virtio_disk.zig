const Buf = @import("../fs/Buf.zig");
const fs = @import("../fs/fs.zig");
const SleepLock = @import("../lock/SleepLock.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const kmem = @import("../memory/kmem.zig");
const fence = @import("../misc.zig").fence;
const assert = @import("../printf.zig").assert;
const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const virtio = @import("../virtio.zig");

const Info = struct { buf: ?*Buf, status: u8 };
var disk = struct {
    /// a set (not a ring) of DMA descriptors, with which the
    /// driver tells the device where to read and write individual
    /// disk operations. there are NUM descriptors.
    /// most commands consist of a "chain" (a linked list) of a couple of
    /// these descriptors.
    desc: *[virtio.num]virtio.VQDesc,

    /// a ring in which the driver writes descriptor numbers
    /// that the driver would like the device to process.  it only
    /// includes the head descriptor of each chain. the ring has
    /// NUM elements.
    avail: *virtio.VQAvail,

    /// a ring in which the device writes descriptor numbers that
    /// the device has finished processing (just the head of each chain).
    /// there are NUM used ring entries.
    used: *virtio.VQUsed,

    // our own book-keeping
    free: [virtio.num]bool, // is a descriptor free?
    used_index: u16, // we've looked this far in used[2..virtio.num]

    /// track info about in-flight operations,
    /// for use when completion interrupt arrives.
    /// indexed by first descriptor index of chain.
    info: [virtio.num]Info,

    /// disk command headers.
    /// one-for-one with descriptors, for convenience.
    ops: [virtio.num]virtio.BlockRequest,

    lock: SpinLock,
}{
    .desc = undefined,
    .avail = undefined,
    .used = undefined,
    .free = [_]bool{false} ** virtio.num,
    .used_index = 0,
    .info = [_]Info{Info{ .buf = null, .status = 0 }} ** virtio.num,
    .ops = [_]virtio.BlockRequest{virtio.BlockRequest{
        .type = .in,
        .sector = 0,
        .reserved = 0,
    }} ** virtio.num,
    .lock = undefined,
};

pub fn init() void {
    disk.lock.init("virtio_disk");

    if (virtio.MMIO.read(.magic_value) != 0x74726976 or
        virtio.MMIO.read(.version) != 2 or
        virtio.MMIO.read(.device_id) != 2 or
        virtio.MMIO.read(.verdor_id) != 0x554d4551)
        panic(@src(), "could not find disk", .{});

    // reset device
    var status: u32 = 0;
    virtio.MMIO.write(.status, status);

    // set ACKNOWLEDGE status bit
    status |= virtio.ConfigStatus.acknowledge;
    virtio.MMIO.write(.status, status);

    // set DRIVER status bit
    status |= virtio.ConfigStatus.driver;
    virtio.MMIO.write(.status, status);

    // negotiate features
    var features = virtio.MMIO.read(.device_features);
    features &= ~@as(u32, (1 << virtio.BlockFeature.ro));
    features &= ~@as(u32, (1 << virtio.BlockFeature.scsi));
    features &= ~@as(u32, (1 << virtio.BlockFeature.config_wce));
    features &= ~@as(u32, (1 << virtio.BlockFeature.mq));
    features &= ~@as(u32, (1 << virtio.feature_any_layout));
    features &= ~@as(u32, (1 << virtio.RingFeature.event_index));
    features &= ~@as(u32, (1 << virtio.RingFeature.indirect_desc));
    virtio.MMIO.write(.driver_features, features);

    // tell device that feature negotiation is complete.
    status |= virtio.ConfigStatus.features_ok;
    virtio.MMIO.write(.status, status);

    // re-read status to ensure features_ok is set.
    status = virtio.MMIO.read(.status);
    if (status & virtio.ConfigStatus.features_ok == 0)
        panic(@src(), "features_ok unset", .{});

    // initialize queue 0.
    virtio.MMIO.write(.queue_sel, 0);

    // ensure queue 0 is not in use
    if (virtio.MMIO.read(.queue_ready) != 0) panic(
        @src(),
        "virtio disk should not be ready",
        .{},
    );

    // check maximum queue size.
    const max = virtio.MMIO.read(.queue_num_max);
    if (max == 0) panic(@src(), "no queue 0", .{});
    if (max < virtio.num) panic(
        @src(),
        "max queue too short({d})",
        .{max},
    );

    // allocate and zero queue memory.
    const desc_page = kmem.alloc() catch panic(
        @src(),
        "desc kalloc failed",
        .{},
    );
    @memset(desc_page, 0);
    disk.desc = @ptrCast(@alignCast(desc_page));

    const avail_page = kmem.alloc() catch panic(
        @src(),
        "avail kalloc failed",
        .{},
    );
    @memset(avail_page, 0);
    disk.avail = @ptrCast(@alignCast(avail_page));

    const used_page = kmem.alloc() catch panic(
        @src(),
        "used kalloc failed",
        .{},
    );
    @memset(used_page, 0);
    disk.used = @ptrCast(@alignCast(used_page));

    // set queue size.
    virtio.MMIO.write(.queue_num, virtio.num);

    // write to physical addresses.
    const desc_addr = @intFromPtr(disk.desc);
    virtio.MMIO.write(.queue_desc_low, @truncate(desc_addr));
    virtio.MMIO.write(.queue_desc_high, @truncate(desc_addr >> 32));
    const avail_addr = @intFromPtr(disk.avail);
    virtio.MMIO.write(.driver_desc_low, @truncate(avail_addr));
    virtio.MMIO.write(.driver_desc_high, @truncate(avail_addr >> 32));
    const used_addr = @intFromPtr(disk.used);
    virtio.MMIO.write(.device_desc_low, @truncate(used_addr));
    virtio.MMIO.write(.device_desc_high, @truncate(used_addr >> 32));

    // queue is ready.
    virtio.MMIO.write(.queue_ready, 0x1);

    // all NUM descriptors start out unused.
    for (0..virtio.num) |i| disk.free[i] = true;

    // tell device we're completely ready.
    status |= virtio.ConfigStatus.driver_ok;
    virtio.MMIO.write(.status, status);

    // plic.zig and trap.zig arrange for interrupts from irq
}

/// find a free descriptor, mark it non-free, return its index.
fn allocDesc() ?u16 {
    for (0..virtio.num) |i| {
        if (disk.free[i]) {
            disk.free[i] = false;
            return @truncate(i);
        }
    }
    return null;
}

/// mark a descriptor as free.
fn freeDesc(i: usize) void {
    assert(i < virtio.num, @src());
    assert(disk.free[i] == false, @src());

    disk.desc[i].addr = 0;
    disk.desc[i].len = 0;
    disk.desc[i].flags = .uninitialized;
    disk.desc[i].next = 0;

    disk.free[i] = true;

    Process.wakeUp(@intFromPtr(disk.desc));
}

/// free a chain of descriptors
fn freeChain(i: usize) void {
    var local_i = i;
    while (true) {
        const flags = disk.desc[local_i].flags;
        const next = disk.desc[local_i].next;
        freeDesc(local_i);
        switch (flags) {
            .next, .next_and_write => {
                local_i = next;
            },
            else => {
                break;
            },
        }
    }
}

/// allocate three descriptors (they need not be contiguous).
/// disk transfers always use three descriptors.
fn allocThreeDescs(indexes: *[3]u16) bool {
    for (0..3) |i| {
        if (allocDesc()) |index| {
            indexes[i] = index;
        } else {
            for (0..i) |j| freeDesc(indexes[j]);
            return false;
        }
    }
    return true;
}

pub fn diskReadWrite(buf: *Buf, is_write: bool) void {
    const sector: u64 = buf.blockno * (fs.block_size / 512);

    disk.lock.acquire();
    defer disk.lock.release();

    // the spec's Section 5.2 says that legacy block operations use
    // three descriptors: one for type/reserved/sector, one for the
    // data, one for a 1-byte status result.

    // allocate the three descriptors.
    var indexes = [_]u16{ 0, 0, 0 };
    while (true) {
        if (allocThreeDescs(&indexes)) {
            break;
        }
        Process.sleep(@intFromPtr(disk.desc), &disk.lock);
    }

    // format the three descriptors.
    // qemu's virtio-blk.c reads them.

    var req: *virtio.BlockRequest = &disk.ops[indexes[0]];

    req.type = if (is_write) .out else .in;
    req.reserved = 0;
    req.sector = sector;

    disk.desc[indexes[0]].addr = @intFromPtr(req);
    disk.desc[indexes[0]].len = @sizeOf(@TypeOf(req.*));
    disk.desc[indexes[0]].flags = .next;
    disk.desc[indexes[0]].next = indexes[1];

    disk.desc[indexes[1]].addr = @intFromPtr(&buf.data);
    disk.desc[indexes[1]].len = fs.block_size;
    disk.desc[indexes[1]].flags = if (is_write) .next else .next_and_write;
    disk.desc[indexes[1]].next = indexes[2];

    disk.info[indexes[0]].status = 0xff; // device writes 0 on success
    disk.desc[indexes[2]].addr = @intFromPtr(&(disk.info[indexes[0]].status));
    disk.desc[indexes[2]].len = 1;
    disk.desc[indexes[2]].flags = .write; // device writes the status
    disk.desc[indexes[2]].next = 0;

    // record struct Buf for intr().
    buf.owned_by_disk = true;
    disk.info[indexes[0]].buf = buf;

    // tell the device the first index in our chain of descriptors.
    disk.avail.ring[disk.avail.index % virtio.num] = indexes[0];

    fence();
    // tell the device another avail ring entry is available.
    disk.avail.index +%= 1;
    fence();

    virtio.MMIO.write(.queue_notify, 0); // value is queue number

    // panic(@src(), "hello", .{});

    // Wait for intr() to say request is finished.
    while (buf.owned_by_disk) Process.sleep(
        @intFromPtr(buf),
        &disk.lock,
    );

    disk.info[indexes[0]].buf = null;
    freeChain(indexes[0]);
}

pub fn intr() void {
    disk.lock.acquire();
    defer disk.lock.release();

    // the device won't raise another interrupt until we tell it
    // we've seen this interrupt, which the following line does.
    // this may race with the device writing new entries to
    // the "used" ring, in which case we may process the new
    // completion entries in this interrupt, and have nothing to do
    // in the next interrupt, which is harmless.
    virtio.MMIO.write(
        .interrupt_ack,
        virtio.MMIO.read(.interrupt_status) & 0x3,
    );

    fence();

    // the device increments disk.used.index when it
    // adds an entry to the used ring.

    while (disk.used_index != disk.used.index) : (disk.used_index +%= 1) {
        fence();
        const id = disk.used.ring[disk.used_index % virtio.num].id;

        assert(disk.info[id].status == 0, @src());

        if (disk.info[id].buf) |buf| {
            buf.owned_by_disk = false;
            Process.wakeUp(@intFromPtr(buf));
        } else {
            panic(@src(), "expect a pre-stored buf channel", .{});
        }
    }
}
