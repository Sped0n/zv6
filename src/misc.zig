///https://github.com/ziglang/zig/blob/52ba2c3a43a88a4db30cff47f2f3eff8c3d5be19/lib/std/special/c.zig#L115
pub fn memMove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        var index: usize = 0;
        while (index != n) : (index += 1) {
            dest[index] = src[index];
        }
    } else {
        var index = n;
        while (index != 0) {
            index -= 1;
            dest[index] = src[index];
        }
    }

    return dest;
}

///Like strncpy but guaranteed to NUL-terminate.
pub fn safeStrCopy(s: [*]u8, t: [*]const u8, n: usize) [*]u8 {
    const os = s;

    if (n <= 0) {
        return os;
    }

    var i: usize = 0;
    while (i < n - 1 and t[i] != 0) : (i += 1) {
        s[i] = t[i];
    }

    s[i] = 0;
    return os;
}
