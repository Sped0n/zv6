const mem = @import("std").mem;

const misc = @import("../misc.zig");
const param = @import("../param.zig");
const panic = @import("../printf.zig").panic;
const Process = @import("../process/Process.zig");
const fs = @import("fs.zig");
const Inode = @import("Inode.zig");

// Paths -----------------------------------------------------------------------

pub const Error = error{
    InodeIsNotDirectory,
    NextLookupFailed,
    TraverseAll,
};

/// Copy the next path element from path into name.
/// Return the current offset after skipping.
/// so the caller can check path.len==curr to see if the name is the last one.
/// If no name to remove, return null.
///
/// Examples:
///   skipElem("a/bb/c", name) = 2, setting name = "a"
///   skipElem("///a//bb", name) = 6, setting name = "a"
///   skipElem("a", name) = 1, setting name = "a"
///   skipElem("", name) = skipElem("////", name) = null
///
fn skipElem(path: []const u8, curr: usize, name_buffer: []u8) usize {
    var local_curr: usize = curr;

    // Skip Leading Slashes
    while (local_curr < path.len and path[local_curr] == '/') {
        local_curr += 1;
    }

    // Check for Empty Path
    if (local_curr == path.len) {
        return 0;
    }

    const start = local_curr;

    // Find the End of the Element
    while (local_curr < path.len and path[local_curr] != '/') {
        local_curr += 1;
    }

    const len = @min(local_curr - start, fs.dir_size - 1);

    // Copy the Element to name
    misc.memMove(name_buffer.ptr, path[start .. start + len].ptr, len);
    name_buffer[len] = 0;

    // Skip Trailing Slashes
    while (local_curr < path.len and path[local_curr] == '/') {
        local_curr += 1;
    }

    return local_curr;
}

/// Look up and return the inode for a path name.
/// If is_parent == true, return the inode for the parent and copy the final
/// path element into name, which must have room for dir_sz bytes.
/// Must be called inside a transaction since it calls iput().
fn lookup(_path: []const u8, comptime is_parent: bool, name_buffer: []u8) !*Inode {
    var inode_ptr: *Inode = undefined;

    if (_path.len > 0 and _path[0] == '/') {
        // absolute path
        inode_ptr = Inode.get(param.root_dev, fs.root_ino);
    } else {
        // relative path
        const curr_proc = Process.current() catch panic(
            @src(),
            "current proc is null, path is {s}",
            .{_path},
        );
        if (curr_proc.cwd) |cwd| {
            inode_ptr = cwd.dup();
        } else {
            panic(
                @src(),
                "current proc(name={s}, pid={d})'s cwd null, path is {s}",
                .{ curr_proc.name, curr_proc.pid, _path },
            );
        }
    }

    var next: *Inode = undefined;
    var path_offset_after_skip: usize = 0;
    while (true) : (inode_ptr = next) {
        path_offset_after_skip = skipElem(
            _path,
            path_offset_after_skip,
            name_buffer,
        );
        if (path_offset_after_skip == 0) break; // no more elements to process

        inode_ptr.lock();

        if (inode_ptr.dinode.type != .directory) {
            inode_ptr.unlockPut();
            return Error.InodeIsNotDirectory;
        }

        if (is_parent and path_offset_after_skip == _path.len) {
            // Stop one level early.
            inode_ptr.unlock();
            return inode_ptr;
        }

        if (inode_ptr.dirLookUp(
            mem.sliceTo(name_buffer, 0),
            null,
        )) |n| {
            next = n;
        } else {
            inode_ptr.unlockPut();
            return Error.NextLookupFailed;
        }

        inode_ptr.unlockPut();
    }

    if (is_parent) {
        inode_ptr.put();
        return Error.TraverseAll;
    }

    return inode_ptr;
}

pub fn toInode(path: []const u8) !*Inode {
    var name_buffer: [fs.dir_size]u8 = [_]u8{0} ** fs.dir_size;
    return lookup(path, false, &name_buffer);
}

pub fn toParentInode(path: []const u8, name_buffer: []u8) !*Inode {
    return lookup(path, true, name_buffer);
}
