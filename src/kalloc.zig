const Spinlock = @import("spinlock.zig");
const memlayout = @import("memlayout.zig");
const riscv = @import("riscv.zig");
const panic = @import("uart.zig").dumbPanic;

const end: *anyopaque = @ptrCast(@extern([*c]c_char, .{ .name = "end" }));

const Block = struct {
    next: ?*Block,
};

var lock: Spinlock = undefined;
var freelist: ?*Block = null;

const Self = @This();

pub fn init() void {
    Spinlock.init(&lock, "kmem");
    freeRange(end, @ptrFromInt(memlayout.phy_stop));
}

fn freeRange(pa_start: *anyopaque, pa_end: *anyopaque) void {
    var p: u64 = riscv.pgRoundUp(@intFromPtr(pa_start));
    const pa_end_in_u64: u64 = @intFromPtr(pa_end);
    while (p + riscv.pg_size <= pa_end_in_u64) : (p += riscv.pg_size) {
        free(@ptrFromInt(p));
    }
}

///Free the page of physical memory pointed at by pa,
///which normally should have been returned by a
///call to kalloc().  (The exception is when
///initializing the allocator; see kinit above.)
pub fn free(pa: *anyopaque) void {
    const pa_in_u64: u64 = @intFromPtr(pa);

    // not aligned.
    if (pa_in_u64 % riscv.pg_size != 0) {
        // TODO: panic
        panic("kfree not aligned");
        return;
    }

    if (pa_in_u64 < @as(
        u64,
        @intFromPtr(end),
    ) or pa_in_u64 >= memlayout.phy_stop) {
        // TODO: panic
        panic("kfree out of range");
        return;
    }

    // fill with junk to catch dangling refs.
    const mem = @as([*]u8, @ptrCast(pa))[0..riscv.pg_size];
    @memset(mem, 1);

    var r: *Block = @alignCast(@ptrCast(pa));

    lock.acquire();
    defer lock.release();

    r.next = freelist;
    freelist = r;
}

///Allocate one 4096-byte page of physical memory.
///Returns a pointer that the kernel can use.
///Returns null if the memory cannot be allocated.
pub fn alloc() ?*anyopaque {
    var r: ?*Block = null;

    {
        lock.acquire();
        defer lock.release();
        r = freelist;
        if (r) |page| {
            freelist = @as(*Block, @ptrCast(page)).next;
        }
    }

    if (r) |page| {
        // fill with junk
        const mem = @as([*]u8, @ptrCast(page))[0..riscv.pg_size];
        @memset(mem, 5);
        return page;
    }

    return null;
}
