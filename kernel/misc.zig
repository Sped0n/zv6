const atomic = @import("std").atomic;

const fs = @import("fs/fs.zig");

var dummy = atomic.Value(u8).init(0);

///https://github.com/ziglang/zig/blob/52ba2c3a43a88a4db30cff47f2f3eff8c3d5be19/lib/std/special/c.zig#L115
pub fn memMove(dst: [*]u8, src: [*]const u8, n: usize) void {
    const src_addr = @intFromPtr(src);
    const dst_addr = @intFromPtr(dst);

    if (src_addr < dst_addr and (src_addr + n) > dst_addr) {
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

pub fn safeStrCopy(dst: [*]u8, src: []const u8, len: usize) void {
    const l = @min(len, dst.len) - 1;
    @memcpy(dst[0..l], src[0..l]);
    dst[l] = 0; // Null-terminate at the end of the copied region
}

///https://ziglang.org/download/0.14.0/release-notes.html#toc-Synchronize-External-Operations
pub fn fence() void {
    _ = dummy.fetchAdd(0, .seq_cst);
}

pub fn memEql(v1: [*]const u8, v2: [*]const u8, len: u32) bool {
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (v1[i] == 0 or v2[i] == 0) return v1[i] == v2[i];

        if (v1[i] != v2[i]) return false;
    }
    return true;
}
