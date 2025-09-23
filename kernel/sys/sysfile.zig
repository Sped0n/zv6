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

    return @intCast(try file.read(
        addr,
        len,
    ));
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

/// Create the path new as a link to the same inode as old.
pub fn link() !u64 {
    var name: [fs.dir_size]u8 = undefined;
    var new: [param.max_path]u8 = undefined;
    var old: [param.max_path]u8 = undefined;

    try argStr(0, &old);
    try argStr(1, &new);

    log.beginOp();
    defer log.endOp();

    // Resolve old path to inode.
    const inode = try path.toInode(mem.sliceTo(&old, 0));

    inode.lock();
    if (inode.dinode.type == .directory) {
        // Hard link to directories is not allowed
        inode.unlockPut();
        return Error.TryToLinkDirectory;
    }
    inode.dinode.nlink += 1;
    inode.update();
    inode.unlock();

    defer inode.put();

    errdefer {
        // Undo.
        inode.lock();
        inode.dinode.nlink -= 1;
        inode.update();
        inode.unlock();
    }

    // Resolve new path's parent directory.
    const parent_inode = try path.toParentInode(
        mem.sliceTo(&new, 0),
        &name,
    );
    parent_inode.lock();
    defer parent_inode.unlockPut();

    if (parent_inode.dev != inode.dev) {
        // Hard link can only be created on the same device.
        return Error.SameDeviceRequired;
    }

    // Also create a new directory entry in the parent directory with
    // the same name that points to the inum of original file.
    try parent_inode.dirLink(
        mem.sliceTo(&name, 0),
        inode.inum,
    );

    return 0;
}

/// Is the directory dp empty except for "." and ".." ?
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
    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    var name: [fs.dir_size]u8 = undefined;

    log.beginOp();
    defer log.endOp();

    var inode: *Inode = undefined;

    {
        // Get parent directory and its name.
        const parent_inode = try path.toParentInode(
            path_slice,
            &name,
        );
        parent_inode.lock();
        defer parent_inode.unlockPut();

        const name_slice: []const u8 = mem.sliceTo(&name, 0);
        if (mem.eql(u8, name_slice, ".") or
            mem.eql(u8, name_slice, ".."))
        {
            // Cannot unlink "." or "..".
            return Error.TryToUnlinkDots;
        }

        var offset: u32 = 0;
        // Lookup inode in directory.
        inode = parent_inode.dirLookUp(name_slice, &offset) orelse {
            return Error.LookUpFailed;
        };

        inode.lock();
        errdefer inode.unlockPut();

        if (inode.dinode.nlink < 1) {
            // File-system inconsistency.
            panic(@src(), "nlink < 1", .{});
        }
        if (inode.dinode.type == .directory and !isDirEmpty(inode)) {
            // Directories must be empty before they can be unlinked.
            return Error.TryToUnlinkNotEmptyDir;
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
    }

    // Decrement link count of inode being unlinked.
    inode.dinode.nlink -= 1;
    inode.update();
    inode.unlockPut();

    return 0;
}

/// Creates a new file or directory at a given path.
///
/// Return a locked inode.
fn create(_path: []const u8, _type: InodeType, major: u16, minor: u16) !*Inode {
    var name: [fs.dir_size]u8 = undefined;

    const parent_inode = try path.toParentInode(
        _path,
        &name,
    );
    const name_slice = mem.sliceTo(&name, 0);

    parent_inode.lock();
    if (parent_inode.dirLookUp(name_slice, null)) |inode| {
        // Entry already existed.
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

    var inode = Inode.alloc(
        parent_inode.dev,
        _type,
    ) orelse return Error.InodeAllocFailed;

    inode.lock();
    // Initialize allocated inode.
    inode.dinode.major = major;
    inode.dinode.minor = minor;
    inode.dinode.nlink = 1;
    inode.update();

    errdefer {
        // De-allocate inode.
        inode.dinode.nlink = 0;
        inode.update();
        inode.unlockPut();
    }

    if (_type == .directory) { // Create . and .. entries.
        // No inode.dinode.nlink += 1: avoid cyclic ref count.
        try inode.dirLink(".", inode.inum);
        try inode.dirLink("..", parent_inode.inum);
    }

    // Create directory entry in parent directory.
    try parent_inode.dirLink(name_slice, inode.inum);

    if (_type == .directory) {
        // Update parent directory link count (if directory),
        // now that success is guaranteed.
        parent_inode.dinode.nlink += 1; // for ".."
        parent_inode.update();
    }

    return inode;
}

pub fn open() !u64 {
    const omode: u64 = argRaw(u64, 1);

    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    log.beginOp();
    defer log.endOp();

    var inode: *Inode = undefined;
    if (omode & @intFromEnum(OpenMode.create) != 0) {
        inode = try create(path_slice, .file, 0, 0);
    } else {
        inode = try path.toInode(path_slice);
        inode.lock();
        if (inode.dinode.type == .directory and
            omode != @intFromEnum(OpenMode.read_only))
        {
            // Users are not allowed to open a read-only directory for writing.
            inode.unlockPut();
            return Error.PermissionDenied;
        }
    }
    errdefer inode.put();
    defer inode.unlock();

    if (inode.dinode.type == .device and
        inode.dinode.major >= param.n_dev)
    {
        // Major device number invalid.
        return Error.DeviceMajorOutOfRange;
    }

    // Allocate file structure and file descriptor.
    const file = try File.alloc();
    errdefer file.close();
    const fd = try fdAlloc(file);

    // Initialize file structure.
    if (inode.dinode.type == .device) {
        file.type = .device;
        file.major = inode.dinode.major;
    } else {
        file.type = .inode;
        file.offset = 0;
    }
    file.inode = inode;
    file.readable = !(omode & @intFromEnum(OpenMode.write_only) != 0);
    file.writable = (omode & @intFromEnum(OpenMode.write_only) != 0) or
        (omode & @intFromEnum(OpenMode.read_write) != 0);

    // Handle truncation.
    if (omode & @intFromEnum(OpenMode.truncate) != 0 and
        inode.dinode.type == .file) inode.truncate();

    return fd;
}

pub fn mkdir() !u64 {
    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    log.beginOp();
    defer log.endOp();

    const inode = try create(path_slice, .directory, 0, 0);
    inode.unlockPut();
    return 0;
}

pub fn mknod() !u64 {
    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

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
    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    const proc = try Process.current();
    assert(proc.cwd != null, @src());

    var inode: *Inode = undefined;

    {
        log.beginOp();
        defer log.endOp();

        inode = try path.toInode(path_slice);

        inode.lock();
        errdefer inode.put();
        defer inode.unlock();

        if (inode.dinode.type != .directory) {
            return Error.ChdirOnNonDirectory;
        }
        proc.cwd.?.put();
    }

    proc.cwd = inode;
    return 0;
}

pub fn exec() !u64 {
    var _path: [param.max_path]u8 = undefined;
    try argStr(0, &_path);
    const path_slice = mem.sliceTo(&_path, 0);

    const uargv: u64 = argRaw(u64, 1);

    var argv = [_]?kmem.Page{null} ** param.max_arg;
    defer for (0..param.max_arg) |j| {
        if (argv[j]) |page| {
            kmem.free(page);
        } else break;
    };

    var i: usize = 0;
    while (true) : (i += 1) {
        if (i >= argv.len) {
            return Error.ArgcOverflow;
        }
        var uarg: u64 = 0;
        try fetchRaw(uargv + @sizeOf(u64) * i, &uarg);
        if (uarg == 0) break;

        argv[i] = try kmem.alloc();
        try fetchStr(uarg, argv[i].?);
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
    errdefer read_file.close();
    errdefer write_file.close();

    const fd0: u32 = @intCast(try fdAlloc(read_file));
    errdefer proc.ofiles[fd0] = null;
    const fd1: u32 = @intCast(try fdAlloc(write_file));
    errdefer proc.ofiles[fd1] = null;

    try vm.copyOut(
        proc.page_table.?,
        fd_array,
        @as([*]const u8, @ptrCast(&fd0)),
        @sizeOf(@TypeOf(fd0)),
    );
    try vm.copyOut(
        proc.page_table.?,
        fd_array + @sizeOf(@TypeOf(fd0)),
        @as([*]const u8, @ptrCast(&fd1)),
        @sizeOf(@TypeOf(fd1)),
    );

    return 0;
}
