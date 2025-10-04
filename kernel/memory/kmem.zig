const std = @import("std");

const assert = @import("../diag.zig").assert;
const SpinLock = @import("../lock/SpinLock.zig");
const memlayout = @import("../memlayout.zig");
const riscv = @import("../riscv.zig");

const log = std.log.scoped(.kmem);

const end = @extern(*u8, .{ .name = "end" });

/// Free list element, located at the beginning of each free page.
const FreeBlock = struct {
    next: ?*FreeBlock,
};

var lock: SpinLock = undefined;
var free_list = struct {
    head: ?*FreeBlock,
}{ .head = null };

pub const Page = *align(4096) [4096]u8;
pub const Error = error{OutOfMemory};

pub fn init() void {
    lock.init("kmem");
    log.info(
        "Claiming memory from 0x{x} to 0x{x}",
        .{ @intFromPtr(end), memlayout.phy_stop },
    );
    const n_pages_claimed = freeRange(@intFromPtr(end), memlayout.phy_stop);
    log.info("{d} pages claimed", .{n_pages_claimed});
    log.info("Page allocator initialized", .{});
}

fn freeRange(start_addr: u64, end_addr: u64) usize {
    var n_pages_claimed: usize = 0;
    var anchor: u64 = riscv.pgRoundUp(start_addr);
    while (anchor + riscv.pg_size <= end_addr) : ({
        anchor += riscv.pg_size;
        n_pages_claimed += 1;
    }) {
        free(@ptrFromInt(anchor));
    }
    return n_pages_claimed;
}

/// Free the page of physical memory pointed at by pa,
/// which normally should have been returned by a
/// call to alloc().  (The exception is when
/// initializing the allocator; see init above.)
pub fn free(page: Page) void {
    const page_addr: u64 = @intFromPtr(page);

    // not aligned
    assert(page_addr % riscv.pg_size == 0);

    // out of range
    assert(page_addr >= @intFromPtr(end) and page_addr < memlayout.phy_stop);

    // fill with junk to catch dangling refs.
    @memset(page, 1);

    var free_block: *FreeBlock = @ptrCast(@alignCast(page));

    lock.acquire();
    defer lock.release();

    free_block.next = free_list.head;
    free_list.head = free_block;
}

/// Allocate one 4096-byte page of physical memory.
/// Returns a pointer that the kernel can use.
/// Returns null if the memory cannot be allocated.
pub fn alloc() !Page {
    var free_block: ?*FreeBlock = null;

    {
        lock.acquire();
        defer lock.release();
        free_block = free_list.head;
        if (free_block) |fb| {
            free_list.head = fb.next;
        }
    }

    if (free_block) |fb| {
        // fill with junk
        const page = @as(Page, @ptrCast(@alignCast(fb)));
        @memset(page, 5);
        return page;
    }

    return Error.OutOfMemory;
}
