const std = @import("std");
const mem = std.mem;

const param = @import("../param.zig");
const Process = @import("../process/Process.zig");
const utils = @import("../utils.zig");
const fs = @import("fs.zig");

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
fn skipElem(path_remaining: []const u8, out_name: []u8) ?[]const u8 {
    var i: usize = 0;

    // Skip Leading Slashes
    while (i < path_remaining.len and path_remaining[i] == '/') {
        i += 1;
    }

    // Check for Empty Path
    if (i == path_remaining.len) {
        return null;
    }

    const start = i;

    // Find the End of the Element
    while (i < path_remaining.len and path_remaining[i] != '/') {
        i += 1;
    }

    const elem_len = @min(i - start, fs.dir_size - 1);

    // Copy the Element to name
    utils.memMove(
        out_name.ptr,
        path_remaining[start .. start + elem_len].ptr,
        elem_len,
    );
    out_name[elem_len] = 0;

    // Skip Trailing Slashes
    while (i < path_remaining.len and path_remaining[i] == '/') {
        i += 1;
    }

    return path_remaining[i..];
}

/// Look up and return the inode for a path name.
/// If is_parent == true, return the inode for the parent and copy the final
/// path element into name, which must have room for dir_sz bytes.
/// Must be called inside a transaction since it calls inode.put().
fn lookup(path: []const u8, comptime is_parent: bool, out_name: []u8) !*fs.Inode {
    var inode: *fs.Inode = undefined;

    if (path.len > 0 and path[0] == '/') {
        // absolute path
        inode = fs.Inode.get(param.root_dev, fs.root_ino);
    } else {
        // relative path
        const curr_proc = Process.current() catch unreachable;
        if (curr_proc.cwd) |cwd| {
            inode = cwd.dup();
        } else {
            unreachable;
        }
    }

    errdefer inode.put();

    var next: *fs.Inode = undefined;
    var path_remaining: []const u8 = path;
    while (true) : (inode = next) {
        const after = skipElem(
            path_remaining,
            out_name,
        ) orelse break;

        {
            inode.lock();
            defer inode.unlock();

            if (inode.dinode.type != .directory) {
                return Error.InodeIsNotDirectory;
            }

            if (is_parent and after.len == 0) {
                // Stop one level early.
                return inode;
            }

            if (inode.dirLookUp(
                mem.sliceTo(out_name, 0),
                null,
            )) |_inode| {
                next = _inode;
            } else {
                return Error.NextLookupFailed;
            }
        }

        inode.put();
        path_remaining = after;
    }

    if (is_parent) {
        return Error.TraverseAll;
    }

    return inode;
}

pub fn toInode(path: []const u8) !*fs.Inode {
    var tmp: [fs.dir_size]u8 = [_]u8{0} ** fs.dir_size;
    return lookup(path, false, &tmp);
}

pub fn toParentInode(path: []const u8, out_name: []u8) !*fs.Inode {
    return lookup(path, true, out_name);
}
