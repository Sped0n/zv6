const atomic = @import("std").atomic;

const fs = @import("fs/fs.zig");

var dummy = atomic.Value(u8).init(0);

///https://github.com/ziglang/zig/blob/52ba2c3a43a88a4db30cff47f2f3eff8c3d5be19/lib/std/special/c.zig#L115
pub fn memMove(dst: [*]u8, src: [*]const u8, n: usize) void {
    @setRuntimeSafety(false);

    const src_addr = @intFromPtr(src);
    const dst_addr = @intFromPtr(dst);

    if (src_addr < dst_addr and src_addr + n > dst_addr) {
        var i = n;
        while (i > 0) : (i -= 1) {
            dst[i] = src[i];
        }
    } else {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = src[i];
        }
    }
}

pub fn safeStrCopy(dst: []u8, src: []const u8) void {
    const l = @min(dst.len, src.len);
    @memcpy(dst[0..l], src[0..l]);
    @memset(dst[l..], 0);
}

///https://ziglang.org/download/0.14.0/release-notes.html#toc-Synchronize-External-Operations
pub fn fence() void {
    _ = dummy.fetchAdd(0, .seq_cst);
}
