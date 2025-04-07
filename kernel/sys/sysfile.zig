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
const elf = @import("../process/elf.zig");
const Process = @import("../process/Process.zig");
const riscv = @import("../riscv.zig");
const argRaw = @import("syscall.zig").argRaw;
const argStr = @import("syscall.zig").argStr;
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

fn argFd(n: usize, fd_ptr: ?*usize, file_ptr: ?**File) !void {
    const fd: u64 = argRaw(u64, n);
    if (fd >= param.n_ofile) return Error.FdOutOfRange;
    const proc = Process.current() catch panic(
        @src(),
        "current proc is null",
        .{},
    );
    if (proc.ofiles[fd]) |ofile| {
        if (fd_ptr) |fdp| fdp.* = fd;
        if (file_ptr) |fp| fp.* = ofile;
    } else {
        return Error.OFileIsNull;
    }
}

fn fdAlloc(file: *File) !usize {
    const proc = try Process.current();

    for (0..param.n_ofile) |fd| {
        if (proc.ofiles[fd] == null) {
            proc.ofiles[fd] = file;
            return fd;
        }
    }

    return Error.OutOfOFiles;
}

pub fn dup() !u64 {
    var file: *File = undefined;
    try argFd(0, null, &file);

    const fd = try fdAlloc(file);
    _ = file.dup();
    return @intCast(fd);
}

pub fn read() !u64 {
    var file: *File = undefined;
    try argFd(0, null, &file);

    const addr: u64 = argRaw(u64, 1);
    const len: u32 = argRaw(u32, 2);

    return @intCast(file.read(
        addr,
        len,
    ) catch |e| return e);
}

pub fn write() !u64 {
    var file: *File = undefined;
    try argFd(0, null, &file);

    const addr: u64 = argRaw(u64, 1);
    const len: u32 = argRaw(u32, 2);

    return @intCast(file.write(
        addr,
        len,
    ) catch |e| return e);
}

pub fn close() !u64 {
    var file: *File = undefined;
    var fd: usize = 0;
    try argFd(0, &fd, &file);

    const proc = try Process.current();
    proc.ofiles[fd] = null;
    file.close();
    return 0;
}

pub fn fileStat() !u64 {
    var file: *File = undefined;
    try argFd(0, null, &file);

    const stat_addr: u64 = argRaw(u64, 1); // user address to struct stat

    try file.stat(stat_addr);
    return 0;
}

///Create the path new as a link to the same inode as old.
pub fn link() !u64 {
    const name = try kmem.ksfba_allocator.alloc(u8, fs.dir_size);
    defer kmem.ksfba_allocator.free(name);
    const new = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(new);
    const old = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(old);

    try argStr(0, old);
    try argStr(1, new);

    log.beginOp();
    defer log.endOp();

    // Resolve old path to inode.
    const inode = try path.toInode(old);

    inode.lock();
    if (inode.dinode.type == .directory) {
        // Hard link to directories is not allowed
        inode.unlockPut();
        return Error.TryToLinkDirectory;
    }
    inode.dinode.nlink += 1;
    inode.update();
    inode.unlock();

    var _error: anyerror = undefined;
    ok_blk: {
        // Resolve new path's parent directory.
        const parent_dir_inode_ptr = path.toParentInode(new, name) catch |e| {
            _error = e;
            break :ok_blk;
        };

        parent_dir_inode_ptr.lock();
        if (parent_dir_inode_ptr.dev != inode.dev) {
            // Hard link can only be created on the same device.
            parent_dir_inode_ptr.unlockPut();

            _error = Error.SameDeviceRequired;
            break :ok_blk;
        }
        // Also create a new directory entry in the parent directory with
        // the same name that points to the inum of original file.
        inode.dirLink(name, inode.inum) catch |e| {
            parent_dir_inode_ptr.unlockPut();

            _error = e;
            break :ok_blk;
        };
        parent_dir_inode_ptr.unlockPut();
        inode.put();

        return 0;
    }

    // Undo.
    inode.lock();
    inode.dinode.nlink -= 1;
    inode.update();
    inode.unlockPut();

    return _error;
}

///Is the directory dp empty except for "." and ".." ?
fn isDirEmpty(dir_inode: *Inode) bool {
    const step = @sizeOf(fs.DirEntry);
    var dir_entry: fs.DirEntry = undefined;
    var offset: u32 = 2 * step;
    while (offset < dir_inode.dinode.size) : (offset += step) {
        assert(
            dir_inode.read(
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
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    const name = try kmem.ksfba_allocator.alloc(u8, fs.dir_size);
    defer kmem.ksfba_allocator.free(name);

    log.beginOp();
    defer log.endOp();

    // Get parent directory and its name.
    const parent_inode = try path.toParentInode(
        path_slice,
        name,
    );
    parent_inode.lock();

    var _error: anyerror = undefined;
    ok_blk: {
        const name_slice: []const u8 = mem.sliceTo(name, 0);
        if (mem.eql(u8, name_slice, ".") or
            mem.eql(u8, name_slice, ".."))
        {
            // Cannot unlink "." or "..".
            _error = Error.TryToUnlinkDots;
            break :ok_blk;
        }

        var offset: u32 = 0;
        // Lookup inode in directory.
        const inode = parent_inode.dirLookUp(name_slice, &offset) orelse {
            _error = Error.LookUpFailed;
            break :ok_blk;
        };
        inode.lock();

        if (inode.dinode.nlink < 1) {
            // File-system inconsistency.
            panic(@src(), "nlink < 1", .{});
        }
        if (inode.dinode.type == .directory and !isDirEmpty(inode)) {
            // Directories must be empty before they can be unlinked.
            inode.unlockPut();

            _error = Error.TryToUnlinkNotEmptyDir;
            break :ok_blk;
        }

        // Clear direcotry entry.
        var dir_entry: fs.DirEntry = undefined;
        const dir_entry_size = @sizeOf(fs.DirEntry);
        @memset(@as([*]u8, @ptrCast(&dir_entry))[0..dir_entry_size], 0);
        assert(
            parent_inode.write(
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
        if (inode.dinode.type == .directory) {
            // Update parent directory link count (if directory).
            parent_inode.dinode.nlink -= 1;
            parent_inode.update();
        }
        parent_inode.unlockPut();

        // Decrement link count of inode being unlinked.
        inode.dinode.nlink -= 1;
        inode.update();
        inode.unlockPut();

        return 0;
    }

    parent_inode.unlockPut();

    return _error;
}

///Creates a new file or directory at a given path.
///
///Return a locked inode.
fn create(_path: []const u8, _type: InodeType, major: u16, minor: u16) !*Inode {
    const name = try kmem.ksfba_allocator.alloc(u8, fs.dir_size);
    defer kmem.ksfba_allocator.free(name);

    const parent_inode = try path.toParentInode(
        _path,
        name,
    );
    const name_slice = mem.sliceTo(name, 0);

    parent_inode.lock();

    var inode: *Inode = undefined;
    if (parent_inode.dirLookUp(name_slice, null)) |_inode| {
        // Entry already existed.
        inode = _inode;
        parent_inode.unlockPut();
        inode.lock();
        if (_type == .file and (inode.dinode.type == .file or
            inode.dinode.type == .device))
        {
            // Return existing file.
            return inode;
        } else {
            inode.unlockPut();
            return Error.EntryAlreadyExisted;
        }
    }

    defer parent_inode.unlockPut();

    inode = Inode.alloc(
        parent_inode.dev,
        _type,
    ) orelse return Error.InodeAllocFailed;

    inode.lock();
    // Initialize allocated inode.
    inode.dinode.major = major;
    inode.dinode.minor = minor;
    inode.dinode.nlink = 1;
    inode.update();

    var _error: anyerror = undefined;
    ok_blk: {
        if (_type == .directory) { // Create . and .. entries.
            // No inode_ptr.dinode.nlink += 1: avoid cyclic ref count.
            inode.dirLink(".", inode.inum) catch |e| {
                _error = e;
                break :ok_blk;
            };
            inode.dirLink(".", parent_inode.inum) catch |e| {
                _error = e;
                break :ok_blk;
            };
        }

        // Create directory entry in parent directory.
        parent_inode.dirLink(name_slice, inode.inum) catch |e| {
            _error = e;
            break :ok_blk;
        };

        if (_type == .directory) {
            // Update parent directory link count (if directory),
            // now that success is guaranteed.
            parent_inode.dinode.nlink += 1; // for ".."
            parent_inode.update();
        }

        return inode;
    }

    // De-allocate inode_ptr.
    inode.dinode.nlink = 0;
    inode.update();
    inode.unlockPut();

    return _error;
}

pub fn open() !u64 {
    const omode: u64 = argRaw(u64, 1);

    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    log.beginOp();
    defer log.endOp();

    var inode: *Inode = undefined;
    const flag = OpenMode.parse(omode);
    switch (flag) {
        .create => {
            inode = try create(path_slice, .file, 0, 0);
        },
        .invalid => {
            return Error.InvalidOpenMode;
        },
        else => {
            inode = try path.toInode(path_slice);
            inode.lock();
            if (inode.dinode.type == .directory and
                flag != .read_only)
            {
                // Users are not allowed to open a read-only directory for writing.
                inode.unlockPut();
                return Error.PermissionDenied;
            }
        },
    }

    if (inode.dinode.type == .device and
        inode.dinode.major >= param.n_dev)
    {
        // Major device number invalid.
        inode.unlockPut();
        return Error.DeviceMajorOutOfRange;
    }

    // Allocate file structure and file descriptor.
    const file = File.alloc() catch |e| {
        inode.unlockPut();
        return e;
    };
    const fd = fdAlloc(file) catch |e| {
        file.close();
        inode.unlockPut();
        return e;
    };

    // Initialize file structure.
    if (inode.dinode.type == .device) {
        file.type = .device;
        file.major = inode.dinode.major;
    } else {
        file.type = .inode;
        file.offset = 0;
    }
    file.inode = inode;
    file.readable = flag != .write_only;
    file.writable = flag == .write_only or flag == .read_write;

    // Handle truncation.
    if (flag == .truncate and
        inode.dinode.type == .file) inode.truncate();

    inode.unlock();

    return fd;
}

pub fn mkdir() !u64 {
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    log.beginOp();
    defer log.endOp();

    const inode = try create(path_slice, .directory, 0, 0);
    inode.unlockPut();
    return 0;
}

pub fn mknod() !u64 {
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    log.beginOp();
    defer log.endOp();

    const major: u16 = argRaw(u16, 1);
    const minor: u16 = argRaw(u16, 2);
    const inode = try create(
        path_slice,
        .device,
        major,
        minor,
    );
    inode.unlockPut();
    return 0;
}

pub fn chdir() !u64 {
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    const proc = try Process.current();
    assert(proc.cwd != null, @src());

    var inode: *Inode = undefined;

    {
        log.beginOp();
        defer log.endOp();

        inode = try path.toInode(path_slice);

        inode.lock();
        if (inode.dinode.type != .directory) {
            inode.unlockPut();
            return Error.ChdirOnNonDirectory;
        }
        inode.unlock();
        proc.cwd.?.put();
    }

    proc.cwd = inode;
    return 0;
}

pub fn exec() !u64 {
    const _path = try kmem.ksfba_allocator.alloc(u8, param.max_path);
    defer kmem.ksfba_allocator.free(_path);
    try argStr(0, _path);
    const path_slice = mem.sliceTo(_path, 0);

    const uargv: u64 = argRaw(u64, 1);

    var argv = try kmem.ksfba_allocator.alloc(*[4096]u8, param.max_arg);
    defer kmem.ksfba_allocator.free(argv);

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
        if (uarg == 0) break;

        argv[i] = try kmem.alloc();
        try fetchStr(uarg, argv[i]);
    }

    return try elf.exec(path_slice, argv[0..i]);
}

pub fn pipe() !u64 {
    const fd_array: u64 = argRaw(u64, 0);

    const proc = try Process.current();
    assert(proc.page_table != null, @src());

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
