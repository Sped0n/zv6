const fs = @import("fs.zig");
const Pipe = @import("Pipe.zig");
const Inode = @import("Inode.zig");
const param = @import("../param.zig");
const SpinLock = @import("../lock/SpinLock.zig");
const log = @import("log.zig");
const Process = @import("../process/Process.zig");
const Stat = @import("stat.zig").Stat;
const vm = @import("../memory/vm.zig");
const assert = @import("../printf.zig").assert;
const panic = @import("../printf.zig").panic;

type: enum { none, pipe, inode, device },
ref: u32,
readable: bool,
writable: bool,
pipe: ?*Pipe,
inode: ?*Inode,
offset: u32,
major: i16,

const Self = @This();

pub const Error = error{
    NotInodeOrDevice,
    PermissionNotValid,
    DeviceMajorNotValid,
    DevswMethodIsNull,
    DevswMethodFailed,
    WrittenLenMismatch,
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

pub const console = 1;

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

///Allocate a file structure/
pub fn alloc() ?*Self {
    file_table.lock.acquire();
    defer file_table.lock.release();

    for (0..param.n_file) |i| {
        const f = &file_table.files[i];
        if (f.ref == 0) {
            f.ref = 1;
            return f;
        }
    }

    return null;
}

///Increment ref count for file f.
pub fn dup(self: *Self) *Self {
    file_table.lock.acquire();
    defer file_table.lock.release();

    assert(self.ref > 0, @src());
    self.ref += 1;
    return self;
}

///Close file f.
///Decrement ref count, close when reaches 0.
pub fn close(self: *Self) void {
    var file: Self = undefined;

    {
        file_table.lock.acquire();
        defer file_table.lock.release();

        assert(self.ref > 0, @src());

        self.ref -= 1;
        if (self.ref > 0) return;

        file = self.*;
        self.ref = 0;
        self.type = .none;
    }

    switch (file.type) {
        .pipe => {
            assert(file.pipe != null, @src());
            file.pipe.?.close(file.writable);
        },
        .inode, .device => {
            assert(file.inode != null, @src());
            log.beginOp();
            defer log.endOp();

            file.inode.?.put();
        },
        .none => {},
    }
}

pub fn stat(self: *Self, user_virt_addr: u64) !void {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    if (self.type != .device and self.type != .inode)
        return Error.NotInodeOrDevice;

    var _stat: Stat = undefined;

    if (self.inode) |inode| {
        inode.lock();
        defer inode.unlock();
        inode.stat(&_stat);
    } else {
        panic(@src(), "inode is null", .{});
        return;
    }

    assert(proc.page_table != null, @src());
    try vm.copyOut(
        proc.page_table.?,
        user_virt_addr,
        @ptrCast(&_stat),
        @sizeOf(Stat),
    );
}

///Read from file.
pub fn read(self: *Self, user_virt_addr: u64, len: u32) !u32 {
    if (!self.readable) return Error.PermissionNotValid;

    switch (self.type) {
        .pipe => {
            assert(self.pipe != null, @src());
            self.pipe.?.read(user_virt_addr, len);
        },
        .device => {
            if (self.major < 0 or
                self.major >= param.n_dev) return Error.DeviceMajorNotValid;

            if (device_switches[self.major].read) |_read| {
                return _read(
                    1,
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
                panic(@src(), "inode is null", .{});
            }
        },
        .none => {
            panic(@src(), "file type is none", .{});
        },
    }
}

///Write to file.
pub fn write(self: *Self, user_virt_addr: u64, len: u32) !u32 {
    if (!self.writable) return Error.PermissionNotValid;

    switch (self.type) {
        .pipe => {
            assert(self.pipe != null, @src());
            self.pipe.?.write(user_virt_addr, len);
        },
        .device => {
            if (self.major < 0 or
                self.major >= param.n_dev) return Error.DeviceMajorNotValid;

            if (device_switches[self.major].write) |_write| {
                return _write(
                    1,
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
                const max = ((param.max_opblocks - 1 - 1 - 2) / 2) * fs.block_size;

                var i: u32 = 0;
                var written: u32 = 0;
                while (i < len) : (i += written) {
                    const rest = @min(max, len - i);

                    {
                        log.beginOp();
                        defer log.endOp();

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
            }
        },
        .none => {
            panic(@src(), "file type is none", .{});
        },
    }
}
