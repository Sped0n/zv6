const Spinlock = @import("spinlock.zig");
const memlayout = @import("memlayout.zig");
const riscv = @import("riscv.zig");
const panic = @import("printf.zig").panic;

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

fn freeRange(start_ptr: *anyopaque, end_ptr: *anyopaque) void {
    var start_addr: u64 = riscv.pgRoundUp(@intFromPtr(start_ptr));
    const end_addr: u64 = @intFromPtr(end_ptr);
    while (start_addr + riscv.pg_size <= end_addr) : ({
        start_addr += riscv.pg_size;
    }) {
        free(@ptrFromInt(start_addr));
    }
}

///Free the page of physical memory pointed at by pa,
///which normally should have been returned by a
///call to alloc().  (The exception is when
///initializing the allocator; see init above.)
pub fn free(page_ptr: *anyopaque) void {
    const page_addr: u64 = @intFromPtr(page_ptr);

    // not aligned.
    if (page_addr % riscv.pg_size != 0) {
        panic(&@src(), "not aligned");
        return;
    }

    if (page_addr < @as(
        u64,
        @intFromPtr(end),
    ) or page_addr >= memlayout.phy_stop) {
        panic(&@src(), "out of range");
        return;
    }

    // fill with junk to catch dangling refs.
    const mem = @as([*]u8, @ptrCast(page_ptr))[0..riscv.pg_size];
    @memset(mem, 1);

    var r: *Block = @alignCast(@ptrCast(page_ptr));

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
