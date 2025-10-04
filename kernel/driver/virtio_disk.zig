const assert = @import("../diag.zig").assert;
const fs = @import("../fs/fs.zig");
const SleepLock = @import("../lock/SleepLock.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const kmem = @import("../memory/kmem.zig");
const Process = @import("../process/Process.zig");
const utils = @import("../utils.zig");
const virtio = @import("../virtio.zig");

const InFlightOperationStatus = enum(u8) {
    started = 0xff,
    finished = 0,
};
const InFlightOperation = struct {
    buffer: ?*fs.Buffer,
    status: InFlightOperationStatus,
};

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
    in_flight_operations: [virtio.num]InFlightOperation,

    /// disk command headers.
    /// one-for-one with descriptors, for convenience.
    block_requests: [virtio.num]virtio.BlockRequest,

    lock: SpinLock,
}{
    .desc = undefined,
    .avail = undefined,
    .used = undefined,
    .free = [_]bool{false} ** virtio.num,
    .used_index = 0,
    .in_flight_operations = [_]InFlightOperation{InFlightOperation{
        .buffer = null,
        .status = .finished,
    }} ** virtio.num,
    .block_requests = [_]virtio.BlockRequest{virtio.BlockRequest{
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
        @panic("could not find disk");

    // reset device
    var status: u32 = 0;
    virtio.MMIO.write(.status, status);

    // set ACKNOWLEDGE status bit
    // status |= flagsMask(virtio.Status, .{.acknowledge});
    status |= @intFromEnum(virtio.Status.acknowledge);
    virtio.MMIO.write(.status, status);

    // set DRIVER status bit
    status |= @intFromEnum(virtio.Status.driver);
    virtio.MMIO.write(.status, status);

    // negotiate features
    var features = virtio.MMIO.read(.device_features);
    const unsupported = @intFromEnum(virtio.Feature.block_ro) |
        @intFromEnum(virtio.Feature.block_scsi) |
        @intFromEnum(virtio.Feature.block_config_wce) |
        @intFromEnum(virtio.Feature.block_mq) |
        @intFromEnum(virtio.Feature.any_layout) |
        @intFromEnum(virtio.Feature.ring_event_index) |
        @intFromEnum(virtio.Feature.ring_indirect_desc);
    features &= ~unsupported;
    virtio.MMIO.write(.driver_features, features);

    // tell device that feature negotiation is complete.
    status |= @intFromEnum(virtio.Status.features_ok);
    virtio.MMIO.write(.status, status);

    // re-read status to ensure features_ok is set.
    status = virtio.MMIO.read(.status);
    assert(status & @intFromEnum(virtio.Status.features_ok) != 0);

    // initialize queue 0.
    virtio.MMIO.write(.queue_sel, 0);

    // ensure queue 0 is not in use
    assert(virtio.MMIO.read(.queue_ready) == 0);

    // check maximum queue size.
    const max = virtio.MMIO.read(.queue_num_max);
    assert(max != 0); // no queue 0
    assert(max >= virtio.num); // max queue too short

    // allocate and zero queue memory.
    const desc_page = kmem.alloc() catch unreachable;
    @memset(desc_page, 0);
    disk.desc = @ptrCast(desc_page);

    const avail_page = kmem.alloc() catch unreachable;
    @memset(avail_page, 0);
    disk.avail = @ptrCast(avail_page);

    const used_page = kmem.alloc() catch unreachable;
    @memset(used_page, 0);
    disk.used = @ptrCast(used_page);

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
    status |= @intFromEnum(virtio.Status.driver_ok);
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
    assert(i < virtio.num);
    assert(disk.free[i] == false);

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

pub fn diskReadWrite(buffer: *fs.Buffer, is_write: bool) void {
    const sector: u64 = buffer.blockno * (fs.block_size / 512);

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

    var request: *virtio.BlockRequest = &disk.block_requests[indexes[0]];

    request.type = if (is_write) .out else .in;
    request.reserved = 0;
    request.sector = sector;

    disk.desc[indexes[0]].addr = @intFromPtr(request);
    disk.desc[indexes[0]].len = @sizeOf(@TypeOf(request.*));
    disk.desc[indexes[0]].flags = .next;
    disk.desc[indexes[0]].next = indexes[1];

    disk.desc[indexes[1]].addr = @intFromPtr(&buffer.data);
    disk.desc[indexes[1]].len = fs.block_size;
    disk.desc[indexes[1]].flags = if (is_write) .next else .next_and_write;
    disk.desc[indexes[1]].next = indexes[2];

    disk.in_flight_operations[indexes[0]].status = .started; // device writes 0 on success
    disk.desc[indexes[2]].addr = @intFromPtr(&(disk.in_flight_operations[indexes[0]].status));
    disk.desc[indexes[2]].len = 1;
    disk.desc[indexes[2]].flags = .write; // device writes the status
    disk.desc[indexes[2]].next = 0;

    // record struct Buf for intr().
    buffer.owned_by_disk = true;
    disk.in_flight_operations[indexes[0]].buffer = buffer;

    // tell the device the first index in our chain of descriptors.
    disk.avail.ring[disk.avail.index % virtio.num] = indexes[0];

    utils.fence();
    // tell the device another avail ring entry is available.
    disk.avail.index +%= 1;
    utils.fence();

    virtio.MMIO.write(.queue_notify, 0); // value is queue number

    // Wait for intr() to say request is finished.
    while (buffer.owned_by_disk) Process.sleep(
        @intFromPtr(buffer),
        &disk.lock,
    );

    disk.in_flight_operations[indexes[0]].buffer = null;
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

    utils.fence();

    // the device increments disk.used.index when it
    // adds an entry to the used ring.

    while (disk.used_index != disk.used.index) : (disk.used_index +%= 1) {
        utils.fence();
        const id = disk.used.ring[disk.used_index % virtio.num].id;

        assert(disk.in_flight_operations[id].status == .finished);

        if (disk.in_flight_operations[id].buffer) |buffer| {
            buffer.owned_by_disk = false;
            Process.wakeUp(@intFromPtr(buffer));
        } else {
            // expect a pre-stored buf channel
            unreachable;
        }
    }
}
