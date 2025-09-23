//
// virtio device definitions.
// for both the mmio interface, and virtio descriptors.
// only tested with qemu.
//
// the virtio spec:
// https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.pdf
//
const memlayout = @import("memlayout.zig");

/// virtio mmio control registers, mapped starting at 0x10001000.
/// from qemu virtio_mmio.h
pub const MMIO = struct {
    const Self = @This();

    pub const Offset = enum(u64) {
        magic_value = 0x000, // 0x74726976
        version = 0x004, // version; should be 2
        status = 0x070, // read/write
        verdor_id = 0x00c, // 0x554d4551

        queue_sel = 0x030, // select queue, write-only
        queue_num_max = 0x034, // max size of current queue, read-only
        queue_num = 0x038, // size of current queue, write-only
        queue_ready = 0x044, // ready bit
        queue_notify = 0x050, // write-only
        interrupt_status = 0x060, // read-only
        interrupt_ack = 0x064, // write-only
        queue_desc_low = 0x080, // physical address for descriptor tablem write-only
        queue_desc_high = 0x084,

        device_id = 0x008, // device type; 1 is net, 2 is disk
        device_features = 0x010,
        device_desc_low = 0x0a0, // physical address for available ring, write only
        device_desc_high = 0x0a4,

        driver_features = 0x020,
        driver_desc_low = 0x090, // physical address for available ring, write-only
        driver_desc_high = 0x094,
    };

    pub inline fn read(offset: Self.Offset) u32 {
        const ptr: *volatile u32 = @ptrFromInt(
            memlayout.virtio0 + @intFromEnum(offset),
        );
        return ptr.*;
    }

    pub inline fn write(offset: Self.Offset, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(
            memlayout.virtio0 + @intFromEnum(offset),
        );
        ptr.* = value;
    }
};

/// status register bits, from qemu virtio_config.h
pub const Status = enum(u32) {
    acknowledge = 1 << 0,
    driver = 1 << 1,
    driver_ok = 1 << 2,
    features_ok = 1 << 3,
};

/// device feature bits
pub const Feature = enum(u32) {
    // Block device features
    block_ro = 1 << 5, // Disk is read-only
    block_scsi = 1 << 7, // Supports scsi command passthru
    block_config_wce = 1 << 11, // Writeback mode available in config
    block_mq = 1 << 12, // Support more than one vq

    // Transport/common feature
    any_layout = 1 << 27,

    // Ring features
    ring_indirect_desc = 1 << 28,
    ring_event_index = 1 << 29,
};

/// this many virtio descriptors.
/// must be a power of two.
pub const num = 8;

/// VRingDesc flags
pub const VRingDescFlag = enum(u16) {
    uninitialized = 0,
    next = 1,
    write = 2,
    next_and_write = 3,
};
/// a single descriptors, from the spec.
pub const VQDesc = extern struct {
    addr: u64,
    len: u32,
    flags: VRingDescFlag,
    next: u16,
};

/// the (entire) avail ring, from the spec.
pub const VQAvail = extern struct {
    flags: u16, // always zero
    index: u16, // driver will
    ring: [num]u16, // descriptor numbers of chain heads
    unused: u16,
};

/// one entry in the "used" rinf, with which the
/// device tells the driver about completed requests.
pub const VQUsedElem = extern struct {
    id: u32, // index of start of completed descriptor chain
    len: u32,
};
pub const VQUsed = extern struct {
    flags: u16, // always zero
    index: u16, // device increments when it adds a ring[] entry
    ring: [num]VQUsedElem,
};

/// these are specific to virtio block devices, e.g. disks,
/// described in Section 5.2 of the spec.
pub const BlockType = enum(u32) {
    in = 0, // read the disk
    out = 1, // write the disk
};

/// the format of the first descriptor in a disk request.
/// to be followed by two more descriptors containing
/// the block, and a one-byte status.
pub const BlockRequest = extern struct {
    type: BlockType,
    reserved: u32,
    sector: u64,
};
