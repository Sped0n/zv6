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

///Copy the next path element from path into name.
///Return the current offset after skipping.
///so the caller can check path.len==curr to see if the name is the last one.
///If no name to remove, return null.
///
///Examples:
///  skipElem("a/bb/c", name) = 2, setting name = "a"
///  skipElem("///a//bb", name) = 6, setting name = "a"
///  skipElem("a", name) = 1, setting name = "a"
///  skipElem("", name) = skipElem("////", name) = null
///
fn skipElem(path: []const u8, name: *[fs.dir_size]u8) usize {
    var curr: usize = 0;

    // Skip Leading Slashes
    while (curr < path.len and path[curr] == '/') {
        curr += 1;
    }

    // Check for Empty Path
    if (curr == path.len) {
        return 0;
    }

    const start = curr;

    // Find the End of the Element
    while (curr < path.len and path[curr] != '/') {
        curr += 1;
    }

    const len = @min(curr - start, fs.dir_size);

    // Copy the Element to name
    const name_ptr = @as([*]u8, name);
    misc.memMove(name_ptr, path[start .. start + len].ptr, len);
    name_ptr[len] = 0;

    // Skip Trailing Slashes
    while (curr < path.len and path[curr] == '/') {
        curr += 1;
    }

    return curr;
}

///Look up and return the inode for a path name.
///If is_parent == true, return the inode for the parent and copy the final
///path element into name, which must have room for dir_sz bytes.
///Must be called inside a transaction since it calls iput().
fn namex(path: []const u8, is_parent: bool, name: *[fs.dir_size]u8) !*Inode {
    var inode_ptr: *Inode = undefined;

    if (path.len > 0 and path[0] == '/') {
        // absolute path
        inode_ptr = Inode.get(param.root_dev, fs.root_ino);
    } else {
        // relative path
        const curr_proc = Process.current() catch panic(
            @src(),
            "current proc is null, path is {s}",
            .{path},
        );
        if (curr_proc.cwd) |cwd| {
            inode_ptr = cwd.dup();
        } else {
            panic(
                @src(),
                "current proc(name={s}, pid={d})'s cwd null, path is {s}",
                .{ curr_proc.name, curr_proc.pid, path },
            );
        }
    }

    var next: *Inode = undefined;
    while (true) : (inode_ptr = next) {
        const path_offset_after_skip = skipElem(path, name);
        if (path_offset_after_skip == 0) break; // no more elements to process

        inode_ptr.lock();

        if (inode_ptr.dinode.type != .directory) {
            inode_ptr.unlockPut();
            return Error.InodeIsNotDirectory;
        }

        if (is_parent and path_offset_after_skip == path.len) {
            // Stop one level early.
            inode_ptr.unlock();
            return inode_ptr;
        }

        if (inode_ptr.dirLookUp(
            mem.sliceTo(name, 0),
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

pub fn namei(path: []const u8) !*Inode {
    var name: [fs.dir_size]u8 = [_]u8{0} ** fs.dir_size;
    return namex(path, false, &name);
}

pub fn nameiParent(path: []const u8, name: *[fs.dir_size]u8) !*Inode {
    return namex(path, true, name);
}
