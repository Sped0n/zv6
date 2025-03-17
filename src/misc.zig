const atomic = @import("std").atomic;

var dummy = atomic.Value(u8).init(0);

///https://github.com/ziglang/zig/blob/52ba2c3a43a88a4db30cff47f2f3eff8c3d5be19/lib/std/special/c.zig#L115
pub fn memMove(dest: [*]u8, src: [*]const u8, n: usize) void {
    const src_addr = @intFromPtr(src);
    const dest_addr = @intFromPtr(dest);

    if (src_addr < dest_addr and (src_addr + n) > dest_addr) {
        var i = n;
        while (i > 0) : (i -= 1) {
            dest[i] = src[i];
        }
    } else {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dest[i] = src[i];
        }
    }
}

pub fn safeStrCopy(dest: []u8, src: []const u8) void {
    if (dest.len == 0) {
        return; // Destination buffer is too small.
    }

    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
    dest[len] = 0; // Null-terminate at the end of the copied region
}

///https://ziglang.org/download/0.14.0/release-notes.html#toc-Synchronize-External-Operations
pub fn fence() void {
    _ = dummy.fetchAdd(0, .seq_cst);
}
