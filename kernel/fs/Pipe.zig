const SpinLock = @import("../lock/SpinLock.zig");
const kmem = @import("../memory/kmem.zig");
const vm = @import("../memory/vm.zig");
const panic = @import("../printf.zig").panic;
const assert = @import("../printf.zig").assert;
const Process = @import("../process/Process.zig");
const File = @import("File.zig");

const pipe_size = 512;

lock: SpinLock,
data: [pipe_size]u8,
n_read: u32,
n_write: u32,
read_open: bool,
write_open: bool,

const Self = @This();

pub const Error = error{
    NotOpened,
    ProcIsKilled,
};

pub fn alloc(file_0: **File, file_1: **File) !void {
    file_0.* = try File.alloc();
    file_1.* = try File.alloc();

    const pipe: *Self = @ptrCast(@alignCast(kmem.alloc() catch |e| {
        file_0.*.close();
        file_1.*.close();
        return e;
    }));

    pipe.read_open = true;
    pipe.write_open = true;
    pipe.n_read = 0;
    pipe.n_write = 0;
    pipe.lock.init("pipe");

    file_0.*.type = .pipe;
    file_0.*.readable = true;
    file_0.*.writable = false;
    file_0.*.pipe = pipe;

    file_1.*.type = .pipe;
    file_1.*.readable = false;
    file_1.*.writable = true;
    file_1.*.pipe = pipe;
}

pub fn close(self: *Self, writable: bool) void {
    var free_pipe = false;
    {
        self.lock.acquire();
        defer self.lock.release();

        if (writable) {
            self.write_open = false;
            Process.wakeUp(@intFromPtr(&self.n_read));
        } else {
            self.read_open = false;
            Process.wakeUp(@intFromPtr(&self.n_write));
        }
        free_pipe = self.read_open == false and self.write_open == false;
    }
    if (free_pipe) kmem.free(@ptrCast(self));
}

pub fn write(self: *Self, virt_addr: u64, len: u32) !u32 {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    self.lock.acquire();
    defer self.lock.release();

    var i: u32 = 0;
    while (i < len) {
        if (self.read_open == false) return Error.NotOpened;
        if (proc.isKilled()) return Error.ProcIsKilled;

        if (self.n_write == self.n_read + pipe_size) { // pipe is full
            Process.wakeUp(@intFromPtr(&self.n_read)); // wakeup readers
            Process.sleep(
                @intFromPtr(&self.n_write),
                &self.lock,
            ); // sleep
        } else {
            assert(proc.page_table != null, @src());
            var char: u8 = 0;
            vm.copyIn(
                proc.page_table.?,
                @ptrCast(&char),
                virt_addr + i,
                1,
            ) catch break;
            self.data[self.n_write % pipe_size] = char;
            self.n_write += 1;
            i += 1;
        }
    }

    Process.wakeUp(@intFromPtr(&self.n_read)); // ensure reading process is notified
    return i;
}

pub fn read(self: *Self, virt_addr: u64, len: u32) !u32 {
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );

    self.lock.acquire();
    defer self.lock.release();

    while (self.n_read == self.n_write and self.write_open) { // pipe is empty
        if (proc.isKilled()) return Error.ProcIsKilled;
        Process.sleep(
            @intFromPtr(&self.n_read),
            &self.lock,
        ); // sleep
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) { // copy
        if (self.n_read == self.n_write) break;

        assert(proc.page_table != null, @src());
        const char = self.data[self.n_read % pipe_size];
        self.n_read += 1;
        vm.copyOut(
            proc.page_table.?,
            virt_addr + i,
            @ptrCast(&char),
            1,
        ) catch break;
    }

    Process.wakeUp(@intFromPtr(&self.n_write)); // ensure writing process is notified
    return i;
}
