const assert = @import("../diag.zig").assert;
const SpinLock = @import("../lock/SpinLock.zig");
const vm = @import("../memory/vm.zig");
const param = @import("../param.zig");
const Process = @import("../process/Process.zig");
const fs = @import("fs.zig");
const Stat = @import("stat.zig").Stat;

type: enum { none, pipe, inode, device },
ref: u32,
readable: bool,
writable: bool,
pipe: ?*fs.Pipe,
inode: ?*fs.Inode,
offset: u32,
major: u16,

const Self = @This();

pub const Error = error{
    OutOfSpace,
    NotInodeOrDevice,
    PermissionDenied,
    MajorOutOfRange,
    DevswMethodIsNull,
    DevswMethodFailed,
    WrittenLenMismatch,
    InodeIsNull,
};

const DeviceSwitch = struct {
    read: ?*const fn (is_user_dst: bool, dst_addr: u64, len: u32) ?u32,
    write: ?*const fn (is_user_dst: bool, dst_addr: u64, len: u32) ?u32,
};
pub var device_switches: [param.n_dev]DeviceSwitch = [_]DeviceSwitch{
    DeviceSwitch{
        .read = null,
        .write = null,
    },
} ** param.n_dev;
pub const DeviceSwitchID = enum(usize) {
    console = 1,
};

var file_table = struct {
    lock: SpinLock,
    files: [param.n_file]Self,
}{
    .lock = undefined,
    .files = [_]Self{Self{
        .type = .none,
        .ref = 0,
        .readable = false,
        .writable = false,
        .pipe = null,
        .inode = null,
        .offset = 0,
        .major = 0,
    }} ** param.n_file,
};

pub fn init() void {
    file_table.lock.init("ftable");
}

/// Allocate a file structure.
pub fn alloc() !*Self {
    file_table.lock.acquire();
    defer file_table.lock.release();

    for (&file_table.files) |*file| {
        if (file.ref == 0) {
            file.ref = 1;
            return file;
        }
    }

    return Error.OutOfSpace;
}

/// Increment ref count for file f.
pub fn dup(self: *Self) *Self {
    file_table.lock.acquire();
    defer file_table.lock.release();

    assert(self.ref > 0);
    self.ref += 1;
    return self;
}

/// Close file f.
/// Decrement ref count, close when reaches 0.
pub fn close(self: *Self) void {
    var copy: Self = undefined;

    {
        file_table.lock.acquire();
        defer file_table.lock.release();

        assert(self.ref > 0);

        self.ref -= 1;
        if (self.ref > 0) return;

        copy = self.*;
        self.ref = 0;
        self.type = .none;
    }

    switch (copy.type) {
        .pipe => {
            assert(copy.pipe != null);
            copy.pipe.?.close(copy.writable);
        },
        .inode, .device => {
            assert(copy.inode != null);
            fs.journal.batch.begin();
            defer fs.journal.batch.end();

            copy.inode.?.put();
        },
        .none => {},
    }
}

pub fn stat(self: *Self, user_virt_addr: u64) !void {
    const proc = Process.current() catch unreachable;

    if (self.type != .device and self.type != .inode)
        return Error.NotInodeOrDevice;

    var _stat: Stat = undefined;

    if (self.inode) |inode| {
        inode.lock();
        defer inode.unlock();
        inode.statCopyTo(&_stat);
    } else {
        unreachable;
    }

    assert(proc.page_table != null);
    try vm.uvm.copyFromKernel(
        proc.page_table.?,
        user_virt_addr,
        @ptrCast(&_stat),
        @sizeOf(Stat),
    );
}

/// Read from file.
pub fn read(self: *Self, user_virt_addr: u64, len: u32) !u32 {
    if (!self.readable) return Error.PermissionDenied;

    switch (self.type) {
        .pipe => {
            assert(self.pipe != null);
            return try self.pipe.?.read(user_virt_addr, len);
        },
        .device => {
            if (self.major >= param.n_dev) return Error.MajorOutOfRange;

            if (device_switches[self.major].read) |_read| {
                return _read(
                    true,
                    user_virt_addr,
                    len,
                ) orelse return Error.DevswMethodFailed;
            } else {
                return Error.DevswMethodIsNull;
            }
        },
        .inode => {
            if (self.inode) |inode| {
                inode.lock();
                defer inode.unlock();

                const r = try inode.read(
                    true,
                    user_virt_addr,
                    self.offset,
                    len,
                );
                self.offset += r;
                return r;
            } else {
                unreachable;
            }
        },
        .none => {
            unreachable;
        },
    }
}

/// Write to file.
pub fn write(self: *Self, user_virt_addr: u64, len: u32) !u32 {
    if (!self.writable) return Error.PermissionDenied;

    switch (self.type) {
        .pipe => {
            assert(self.pipe != null);
            return try self.pipe.?.write(user_virt_addr, len);
        },
        .device => {
            if (self.major >= param.n_dev) return Error.MajorOutOfRange;

            if (device_switches[self.major].write) |_write| {
                return _write(
                    true,
                    user_virt_addr,
                    len,
                ) orelse return Error.DevswMethodFailed;
            } else {
                return Error.DevswMethodIsNull;
            }
        },
        .inode => {
            if (self.inode) |inode| {
                // write a few blocks at a time to avoid exceeding
                // the maximum log transaction size, including
                // i-node, indirect block, allocation blocks,
                // and 2 blocks of slop for non-aligned writes.
                // this really belongs lower down, since Inode.write()
                // might be writing a device like the console.
                const max =
                    ((param.max_opblocks - 1 - 1 - 2) / 2) * fs.block_size;

                var i: u32 = 0;
                var written: u32 = 0;
                while (i < len) : (i += written) {
                    const rest = @min(max, len - i);

                    {
                        fs.journal.batch.begin();
                        defer fs.journal.batch.end();

                        inode.lock();
                        defer inode.unlock();

                        written = try inode.write(
                            true,
                            user_virt_addr + i,
                            self.offset,
                            rest,
                        );

                        if (written > 0) self.offset += written;
                        if (written != rest) return Error.WrittenLenMismatch;
                    }
                }

                return len;
            } else {
                return Error.InodeIsNull;
            }
        },
        .none => {
            unreachable;
        },
    }
}
