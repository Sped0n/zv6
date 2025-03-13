const SpinLock = @import("../lock/SpinLock.zig");
const memlayout = @import("../memlayout.zig");
const panic = @import("../printf.zig").panic;
const printf = @import("../printf.zig").printf;
const riscv = @import("../riscv.zig");

const end = @extern(*u8, .{ .name = "end" });

const Block = struct {
    next: ?*Block,
};

var lock: SpinLock = undefined;
var freelist: ?*Block = null;

pub fn init() void {
    lock.init("kmem");
    freeRange(@intFromPtr(end), memlayout.phy_stop);
}

fn freeRange(start_addr: u64, end_addr: u64) void {
    var local_start_addr: u64 = riscv.pgRoundUp(start_addr);
    while (local_start_addr + riscv.pg_size <= end_addr) : ({
        local_start_addr += riscv.pg_size;
    }) {
        free(@ptrFromInt(local_start_addr));
    }
}

///Free the page of physical memory pointed at by pa,
///which normally should have been returned by a
///call to alloc().  (The exception is when
///initializing the allocator; see init above.)
pub fn free(page_ptr: *[4096]u8) void {
    const page_addr: u64 = @intFromPtr(page_ptr);

    // not aligned.
    if (page_addr % riscv.pg_size != 0) {
        panic(@src().fn_name, "not aligned", .{});
        return;
    }

    if (page_addr < @as(
        u64,
        @intFromPtr(end),
    ) or page_addr >= memlayout.phy_stop) {
        panic(@src().fn_name, "out of range", .{});
        return;
    }

    // fill with junk to catch dangling refs.
    @memset(page_ptr, 1);

    var r: *Block = @ptrFromInt(@intFromPtr(page_ptr));

    lock.acquire();
    defer lock.release();

    r.next = freelist;
    freelist = r;
}

///Allocate one 4096-byte page of physical memory.
///Returns a pointer that the kernel can use.
///Returns null if the memory cannot be allocated.
pub fn alloc() ?*[4096]u8 {
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
        const mem = @as(*[4096]u8, @ptrCast(page));
        @memset(mem, 5);
        return mem;
    }

    return null;
}
