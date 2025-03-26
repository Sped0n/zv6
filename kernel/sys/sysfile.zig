const mem = @import("std").mem;

const OpenMode = @import("../fcntl.zig").OpenMode;
const InodeType = @import("../fs/dinode.zig").InodeType;
const File = @import("../fs/File.zig");
const fs = @import("../fs/fs.zig");
const Inode = @import("../fs/Inode.zig");
const log = @import("../fs/log.zig");
const path = @import("../fs/path.zig");
const Pipe = @import("../fs/Pipe.zig");
const kmem = @import("../memory/kmem.zig");
const vm = @import("../memory/vm.zig");
const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;
const assert = @import("../printf.zig").assert;
const printf = @import("../printf.zig").printf;
const elf = @import("../process/elf.zig");
const Process = @import("../process/Process.zig");
const riscv = @import("../riscv.zig");
const argRaw = @import("syscall.zig").argRaw;
const argStr = @import("syscall.zig").argStr;
const argU32 = @import("syscall.zig").argU32;
const fetchRaw = @import("syscall.zig").fetchRaw;
const fetchStr = @import("syscall.zig").fetchStr;

//
// File-system system calls.
// Mostly argument checking, since we don't trust
// user code, and calls into File.zig and fs.zig.
//

const Error = error{
    FdOutOfRange,
    OFileIsNull,
    OutOfOFiles,
    TryToLinkDirectory,
    SameDeviceRequired,
    TryToUnlinkDots,
    LookUpFailed,
    TryToUnlinkNotEmptyDir,
    EntryAlreadyExisted,
    InodeAllocFailed,
    InvalidOpenMode,
    PermissionDenied,
    DeviceMajorOutOfRange,
    ChdirOnNonDirectory,
    ArgcOverflow,
};

fn argFd(n: usize, fd_ptr: ?*usize, ofile_ptr: ?**File) !void {
    const fd = argRaw(n);
    if (fd >= param.n_ofile) return Error.FdOutOfRange;
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    if (proc.ofiles[fd]) |ofile| {
        if (fd_ptr) |fdp| fdp.* = fd;
        if (ofile_ptr) |ofp| ofp.* = ofile;
    } else {
        return Error.OFileIsNull;
    }
}

fn fdAlloc(file_ptr: *File) !usize {
    const proc = try Process.current();

    for (0..param.n_ofile) |fd| {
        if (proc.ofiles[fd] == null) {
            proc.ofiles[fd] = file_ptr;
            return fd;
        }
    }

    return Error.OutOfOFiles;
}

pub fn dup() !u64 {
    var file_ptr: *File = undefined;
    try argFd(0, null, &file_ptr);
    const fd = try fdAlloc(file_ptr);

    _ = file_ptr.dup();
    return @intCast(fd);
}

pub fn read() !u64 {
    const addr = argRaw(1);
    const len = argU32(2);
    var file_ptr: *File = undefined;
    try argFd(0, null, &file_ptr);

    return @intCast(file_ptr.read(
        addr,
        len,
    ) catch |e| return e);
}

pub fn write() !u64 {
    const addr = argRaw(1);
    const len = argU32(2);
    var file_ptr: *File = undefined;
    try argFd(0, null, &file_ptr);

    return @intCast(file_ptr.write(
        addr,
        len,
    ) catch |e| return e);
}

pub fn close() !u64 {
    var file_ptr: *File = undefined;
    var fd: usize = 0;
    try argFd(0, &fd, &file_ptr);

    const proc = try Process.current();
    proc.ofiles[fd] = null;
    file_ptr.close();
    return 0;
}

pub fn fileStat() !u64 {
    const stat_addr = argRaw(1); // user address to struct stat
    var file_ptr: *File = undefined;
    try argFd(0, null, &file_ptr);

    try file_ptr.stat(stat_addr);
    return 0;
}

///Create the path new as a link to the same inode as old.
pub fn link() !u64 {
    var name = [_]u8{0} ** fs.dir_size;
    var new = [_]u8{0} ** param.max_path;
    var old = [_]u8{0} ** param.max_path;

    try argStr(0, &old);
    try argStr(1, &new);

    log.beginOp();
    defer log.endOp();

    // Resolve old path to inode.
    const inode_ptr = try path.namei(&old);

    inode_ptr.lock();
    if (inode_ptr.dinode.type == .directory) {
        // Hard link to directories is not allowed
        inode_ptr.unlockPut();
        return Error.TryToLinkDirectory;
    }
    inode_ptr.dinode.nlink += 1;
    inode_ptr.update();
    inode_ptr.unlock();

    var _error: anyerror = undefined;
    ok_blk: {
        // Resolve new path's parent directory.
        const parent_dir_inode_ptr = path.nameiParent(&new, &name) catch |e| {
            _error = e;
            break :ok_blk;
        };

        parent_dir_inode_ptr.lock();
        if (parent_dir_inode_ptr.dev != inode_ptr.dev) {
            // Hard link can only be created on the same device.
            parent_dir_inode_ptr.unlockPut();

            _error = Error.SameDeviceRequired;
            break :ok_blk;
        }
        // Also create a new directory entry in the parent directory with
        // the same name that points to the inum of original file.
        inode_ptr.dirLink(&name, inode_ptr.inum) catch |e| {
            parent_dir_inode_ptr.unlockPut();

            _error = e;
            break :ok_blk;
        };
        parent_dir_inode_ptr.unlockPut();
        inode_ptr.put();

        return 0;
    }

    // Undo.
    inode_ptr.lock();
    inode_ptr.dinode.nlink -= 1;
    inode_ptr.update();
    inode_ptr.unlockPut();

    return _error;
}

///Is the directory dp empty except for "." and ".." ?
fn isDirEmpty(dir_ptr: *Inode) bool {
    const step = @sizeOf(fs.DirEntry);
    var dir_entry: fs.DirEntry = undefined;
    var offset: u32 = 2 * step;
    while (offset < dir_ptr.dinode.size) : (offset += step) {
        assert(
            dir_ptr.read(
                false,
                @intFromPtr(&dir_entry),
                offset,
                step,
            ) catch |e| {
                panic(@src(), "Inode.read failed with {s}", .{@errorName(e)});
            } == step,
            @src(),
        );
        if (dir_entry.inum != 0) return false;
    }
    return true;
}

pub fn unlink() !u64 {
    var _path = [_]u8{0} ** param.max_path;
    try argStr(0, &_path);

    log.beginOp();
    defer log.endOp();

    var name = [_]u8{0} ** fs.dir_size;
    // Get parent directory and its name.
    const parent_dir_inode_ptr = try path.nameiParent(mem.sliceTo(&_path, 0), &name);
    parent_dir_inode_ptr.lock();

    var _error: anyerror = undefined;
    ok_blk: {
        const name_slice: []const u8 = mem.sliceTo(&name, 0);
        if (mem.eql(u8, name_slice, ".") or
            mem.eql(u8, name_slice, ".."))
        {
            // Cannot unlink "." or "..".
            _error = Error.TryToUnlinkDots;
            break :ok_blk;
        }

        var offset: u32 = 0;
        // Lookup inode in directory.
        const inode_ptr = parent_dir_inode_ptr.dirLookUp(name_slice, &offset) orelse {
            _error = Error.LookUpFailed;
            break :ok_blk;
        };
        inode_ptr.lock();

        if (inode_ptr.dinode.nlink < 1) {
            // File-system inconsistency.
            panic(@src(), "nlink < 1", .{});
        }
        if (inode_ptr.dinode.type == .directory and !isDirEmpty(inode_ptr)) {
            // Directories must be empty before they can be unlinked.
            inode_ptr.unlockPut();

            _error = Error.TryToUnlinkNotEmptyDir;
            break :ok_blk;
        }

        // Clear direcotry entry.
        var dir_entry: fs.DirEntry = undefined;
        const dir_entry_size = @sizeOf(fs.DirEntry);
        @memset(@as([*]u8, @ptrCast(&dir_entry))[0..dir_entry_size], 0);
        assert(
            parent_dir_inode_ptr.write(
                false,
                @intFromPtr(&dir_entry),
                offset,
                dir_entry_size,
            ) catch |e| panic(
                @src(),
                "Inode.write failed with {s}",
                .{@errorName(e)},
            ) == dir_entry_size,
            @src(),
        );
        if (inode_ptr.dinode.type == .directory) {
            // Update parent directory link count (if directory).
            parent_dir_inode_ptr.dinode.nlink -= 1;
            parent_dir_inode_ptr.update();
        }
        parent_dir_inode_ptr.unlockPut();

        // Decrement link count of inode being unlinked.
        inode_ptr.dinode.nlink -= 1;
        inode_ptr.update();
        inode_ptr.unlockPut();

        return 0;
    }

    parent_dir_inode_ptr.unlockPut();

    return _error;
}

///Creates a new file or directory at a given path.
///
///Return a locked inode.
fn create(_path: []const u8, _type: InodeType, major: u16, minor: u16) !*Inode {
    var name = [_]u8{0} ** fs.dir_size;

    const parent_dir_inode_ptr = try path.nameiParent(_path, &name);
    const name_slice = mem.sliceTo(&name, 0);

    parent_dir_inode_ptr.lock();

    var inode_ptr: *Inode = undefined;
    if (parent_dir_inode_ptr.dirLookUp(name_slice, null)) |ip| {
        // Entry already existed.
        inode_ptr = ip;
        parent_dir_inode_ptr.unlockPut();
        inode_ptr.lock();
        if (_type == .file and (inode_ptr.dinode.type == .file or
            inode_ptr.dinode.type == .device))
        {
            // Return existing file.
            return inode_ptr;
        } else {
            inode_ptr.unlockPut();
            return Error.EntryAlreadyExisted;
        }
    }

    defer parent_dir_inode_ptr.unlockPut();

    inode_ptr = Inode.alloc(
        parent_dir_inode_ptr.dev,
        _type,
    ) orelse return Error.InodeAllocFailed;

    inode_ptr.lock();
    // Initialize allocated inode.
    inode_ptr.dinode.major = major;
    inode_ptr.dinode.minor = minor;
    inode_ptr.dinode.nlink = 1;
    inode_ptr.update();

    var _error: anyerror = undefined;
    ok_blk: {
        if (_type == .directory) { // Create . and .. entries.
            // No inode_ptr.dinode.nlink += 1: avoid cyclic ref count.
            inode_ptr.dirLink(".", inode_ptr.inum) catch |e| {
                _error = e;
                break :ok_blk;
            };
            inode_ptr.dirLink(".", parent_dir_inode_ptr.inum) catch |e| {
                _error = e;
                break :ok_blk;
            };
        }

        // Create directory entry in parent directory.
        parent_dir_inode_ptr.dirLink(name_slice, inode_ptr.inum) catch |e| {
            _error = e;
            break :ok_blk;
        };

        if (_type == .directory) {
            // Update parent directory link count (if directory),
            // now that success is guaranteed.
            parent_dir_inode_ptr.dinode.nlink += 1; // for ".."
            parent_dir_inode_ptr.update();
        }

        return inode_ptr;
    }

    // De-allocate inode_ptr.
    inode_ptr.dinode.nlink = 0;
    inode_ptr.update();
    inode_ptr.unlockPut();

    return _error;
}

pub fn open() !u64 {
    const omode = argRaw(1);

    var _path = [_]u8{0} ** param.max_path;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    log.beginOp();
    defer log.endOp();

    var inode_ptr: *Inode = undefined;
    const open_mode_flag = OpenMode.parse(omode);
    switch (open_mode_flag) {
        .create => {
            inode_ptr = try create(path_slice, .file, 0, 0);
        },
        .invalid => {
            return Error.InvalidOpenMode;
        },
        else => {
            inode_ptr = try path.namei(path_slice);
            inode_ptr.lock();
            if (inode_ptr.dinode.type == .directory and
                open_mode_flag == .read_only)
            {
                // Users are not allowed to open a read-only directory for writing.
                inode_ptr.unlockPut();
                return Error.PermissionDenied;
            }
        },
    }

    if (inode_ptr.dinode.type == .device and
        inode_ptr.dinode.major >= param.n_dev)
    {
        // Major device number invalid.
        inode_ptr.unlockPut();
        return Error.DeviceMajorOutOfRange;
    }

    // Allocate file structure and file descriptor.
    const file_ptr = File.alloc() catch |e| {
        inode_ptr.unlockPut();
        return e;
    };
    const fd = fdAlloc(file_ptr) catch |e| {
        file_ptr.close();
        inode_ptr.unlockPut();
        return e;
    };

    // Initialize file structure.
    if (inode_ptr.dinode.type == .device) {
        file_ptr.type = .device;
        file_ptr.major = inode_ptr.dinode.major;
    } else {
        file_ptr.type = .inode;
        file_ptr.offset = 0;
    }
    file_ptr.inode = inode_ptr;
    file_ptr.readable = open_mode_flag != .write_only;
    file_ptr.writable = open_mode_flag == .write_only or
        open_mode_flag == .read_write;

    // Handle truncation.
    if (open_mode_flag == .truncate and
        inode_ptr.dinode.type == .file) inode_ptr.trunc();

    inode_ptr.unlock();

    return fd;
}

pub fn mkdir() !u64 {
    var _path = [_]u8{0} ** param.max_path;

    log.beginOp();
    defer log.endOp();

    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);
    const inode_ptr = try create(path_slice, .directory, 0, 0);
    inode_ptr.unlockPut();
    return 0;
}

pub fn mknod() !u64 {
    var _path = [_]u8{0} ** param.max_path;

    log.beginOp();
    defer log.endOp();

    const major: u16 = @intCast(argRaw(1));
    const minor: u16 = @intCast(argRaw(2));
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);
    const inode_ptr = try create(
        path_slice,
        .device,
        major,
        minor,
    );
    inode_ptr.unlockPut();
    return 0;
}

pub fn chdir() !u64 {
    const proc = try Process.current();
    assert(proc.cwd != null, @src());
    var _path = [_]u8{0} ** param.max_path;
    var inode_ptr: *Inode = undefined;

    {
        log.beginOp();
        defer log.endOp();

        try argStr(0, &_path);
        const path_slice = mem.sliceTo(&_path, 0);
        inode_ptr = try path.namei(path_slice);

        inode_ptr.lock();
        if (inode_ptr.dinode.type != .directory) {
            inode_ptr.unlockPut();
            return Error.ChdirOnNonDirectory;
        }
        inode_ptr.unlock();
        proc.cwd.?.put();
    }

    proc.cwd = inode_ptr;
    return 0;
}

pub fn exec() !u64 {
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    var argv = try kmem.ksfba_allocator.alloc(*[4096]u8, param.max_arg);
    defer kmem.ksfba_allocator.free(argv);

    const uargv = argRaw(1);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    var i: usize = 0;
    defer for (0..i) |j| {
        kmem.free(argv[j]);
    };
    while (true) : (i += 1) {
        if (i >= argv.len) {
            return Error.ArgcOverflow;
        }
        var uarg: u64 = 0;
        try fetchRaw(uargv + @sizeOf(u64) * i, &uarg);
        printf("uarg: {d}\n", .{uarg});
        if (uarg == 0) break;

        argv[i] = try kmem.alloc();
        try fetchStr(uarg, argv[i], riscv.pg_size);
    }

    return try elf.exec(path_slice, argv[0..i]);
}

pub fn pipe() !u64 {
    const proc = try Process.current();
    assert(proc.page_table != null, @src());

    const fd_array = argRaw(0);

    var read_file: *File = undefined;
    var write_file: *File = undefined;
    try Pipe.alloc(&read_file, &write_file);

    const fd0: u32 = @intCast(fdAlloc(read_file) catch |e| {
        read_file.close();
        write_file.close();
        return e;
    });
    const fd1: u32 = @intCast(fdAlloc(write_file) catch |e| {
        proc.ofiles[fd0] = null;
        read_file.close();
        write_file.close();
        return e;
    });

    vm.copyOut(
        proc.page_table.?,
        fd_array,
        @as([*]const u8, @ptrCast(&fd0)),
        @sizeOf(@TypeOf(fd0)),
    ) catch |e| {
        proc.ofiles[fd0] = null;
        proc.ofiles[fd1] = null;
        read_file.close();
        write_file.close();
        return e;
    };
    vm.copyOut(
        proc.page_table.?,
        fd_array,
        @as([*]const u8, @ptrCast(&fd1)),
        @sizeOf(@TypeOf(fd1)),
    ) catch |e| {
        proc.ofiles[fd0] = null;
        proc.ofiles[fd1] = null;
        read_file.close();
        write_file.close();
        return e;
    };

    return 0;
}
