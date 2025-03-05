///https://github.com/ziglang/zig/blob/52ba2c3a43a88a4db30cff47f2f3eff8c3d5be19/lib/std/special/c.zig#L115
pub fn memMove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
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

///We only use this in process name copying, so its okay to use fixed size.
pub fn safeStrCopy(dest: *[16]u8, src: []const u8) void {
    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
    dest[len + 1] = 0;
}
