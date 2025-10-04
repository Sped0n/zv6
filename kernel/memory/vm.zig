const std = @import("std");

const assert = @import("../diag.zig").assert;
const memlayout = @import("../memlayout.zig");
const kmem = @import("../memory/kmem.zig");
const Process = @import("../process/Process.zig");
const riscv = @import("../riscv.zig");
const utils = @import("../utils.zig");

const log = std.log.scoped(.vm);

// kernel.ld set this to end of kernel code.
const etext = @extern(*u8, .{ .name = "etext" });

// trampoline.S
const trampoline = @extern(*u8, .{ .name = "trampoline" });

pub const Error = error{
    TryWalkIntoInvalidPage,
    PTEFlagNotV,
    PTEFlagNotU,
    PTEFlagNotW,
    VAOutOfRange,
    NotNullTerminated,
};

/// kernel page table
var kernel_page_table: riscv.PageTable = undefined;

/// Return the address of the PTE in page table pagetable
/// that corresponds to virtual address va.  If alloc is
/// true, create any required page-table pages.
//
/// The risc-v Sv39 scheme has three levels of page-table
/// pages. A page-table page contains 512 64-bit PTEs.
/// A 64-bit virtual address is split into five fields:
///   39..63 -- must be zero.
///   30..38 -- 9 bits of level-2 index.
///   21..29 -- 9 bits of level-1 index.
///   12..20 -- 9 bits of level-0 index.
///    0..11 -- 12 bits of byte offset within the page.
pub fn walk(
    page_table: riscv.PageTable,
    virt_addr: u64,
    alloc: bool,
) !*riscv.Pte {
    assert(virt_addr <= riscv.max_va);

    var current_page_table = page_table;

    var level: u64 = 2;
    while (level > 0) : (level -= 1) {
        const pte_ptr: *riscv.Pte = &current_page_table[
            riscv.pageTableIdxFromVa(
                level,
                virt_addr,
            )
        ];

        if (pte_ptr.* & @intFromEnum(riscv.PteFlag.v) != 0) {
            current_page_table = @ptrFromInt(riscv.paFromPte(pte_ptr.*));
            continue;
        }

        if (!alloc) return Error.TryWalkIntoInvalidPage;

        const page = try kmem.alloc();
        @memset(page, 0);
        current_page_table = @ptrCast(page);
        pte_ptr.* = riscv.pteFromPa(
            @intFromPtr(current_page_table),
        ) | @intFromEnum(riscv.PteFlag.v);
    }

    return &current_page_table[riscv.pageTableIdxFromVa(0, virt_addr)];
}

/// Look up a virtual address, return the physical address,
/// or null if not mapped.
/// Can only be used to look up user pages.
pub fn walkAddr(page_table: riscv.PageTable, virt_addr: u64) !u64 {
    if (virt_addr >= riscv.max_va) return Error.VAOutOfRange;

    const pte = (try walk(
        page_table,
        virt_addr,
        false,
    )).*;

    if ((pte & @intFromEnum(riscv.PteFlag.v)) == 0) return Error.PTEFlagNotV;
    if ((pte & @intFromEnum(riscv.PteFlag.u)) == 0) return Error.PTEFlagNotU;

    const phy_addr = riscv.paFromPte(pte);
    return phy_addr;
}

/// Create PTEs for virtual addresses starting at va that refer to
/// physical addresses starting at pa.
/// va and size MUST be page-aligned.
/// Returns true on success, false if walk() couldn't
/// allocate a needed page-table page.
pub fn mapPages(
    page_table: riscv.PageTable,
    virt_addr: u64,
    size: u64,
    phy_addr: u64,
    permission: u64,
) !void {
    assert(virt_addr % riscv.pg_size == 0);
    assert(size % riscv.pg_size == 0);
    assert(size > 0);

    var virt_anchor: u64 = virt_addr;
    var phy_anchor: u64 = phy_addr;
    const virt_last: u64 = virt_addr + size - riscv.pg_size;

    while (virt_anchor <= virt_last) : ({
        virt_anchor += riscv.pg_size;
        phy_anchor += riscv.pg_size;
    }) {
        const pte_ptr = try walk(
            page_table,
            virt_anchor,
            true,
        );

        // try to remap existing page
        assert(pte_ptr.* & @intFromEnum(riscv.PteFlag.v) == 0);

        pte_ptr.* = riscv.pteFromPa(
            phy_anchor,
        ) | permission | @intFromEnum(
            riscv.PteFlag.v,
        );
    }
}

/// Recursively free page-table pages.
/// All leaf mappings must already have been removed.
pub fn freeWalk(page_table: riscv.PageTable) void {
    const v_permission = @intFromEnum(riscv.PteFlag.v);
    const rwx_permission = @intFromEnum(riscv.PteFlag.r) |
        @intFromEnum(riscv.PteFlag.w) |
        @intFromEnum(riscv.PteFlag.x);
    // there are 2^9 = 512 PTEs in a page table
    for (0..512) |i| {
        const pte = page_table[i];
        if ((pte & v_permission != 0) and (pte & rwx_permission == 0)) {
            // this PTE points to a lower level page table
            const child: riscv.PageTable = @ptrFromInt(riscv.paFromPte(pte));
            freeWalk(child);
            page_table[i] = 0;
        } else if (pte & v_permission != 0) {
            // all leaf mappings must be removed before calling freeWalk
            unreachable;
        }
    }
    kmem.free(@ptrCast(@alignCast(page_table)));
}

pub const kvm = struct {
    pub fn make() !riscv.PageTable {
        const kpgtbl: riscv.PageTable = @ptrCast(try kmem.alloc());

        const mem: *[4096]u8 = @ptrCast(kpgtbl);
        @memset(mem, 0);

        const rw_permission: u64 = @intFromEnum(
            riscv.PteFlag.r,
        ) | @intFromEnum(
            riscv.PteFlag.w,
        );
        const rx_permission: u64 = @intFromEnum(
            riscv.PteFlag.r,
        ) | @intFromEnum(
            riscv.PteFlag.x,
        );

        // uart register
        kvm.map(
            kpgtbl,
            memlayout.uart0,
            memlayout.uart0,
            riscv.pg_size,
            rw_permission,
        );

        // virtio mmio disk interface
        kvm.map(
            kpgtbl,
            memlayout.virtio0,
            memlayout.virtio0,
            riscv.pg_size,
            rw_permission,
        );

        // PLIC
        kvm.map(
            kpgtbl,
            memlayout.plic,
            memlayout.plic,
            0x4000000,
            rw_permission,
        );

        // map kernel text executable and read-only.
        kvm.map(
            kpgtbl,
            memlayout.kernel_base,
            memlayout.kernel_base,
            @intFromPtr(etext) - memlayout.kernel_base,
            rx_permission,
        );

        // map kernel data and physical RAM we'll make use of.
        kvm.map(
            kpgtbl,
            @intFromPtr(etext),
            @intFromPtr(etext),
            memlayout.phy_stop - @intFromPtr(etext),
            rw_permission,
        );

        // map the trampoline for trap entry/exit to
        // the highest virtual address in the kernel.
        kvm.map(
            kpgtbl,
            memlayout.trampoline,
            @intFromPtr(trampoline),
            riscv.pg_size,
            rx_permission,
        );

        // allocate and map a kernel stack for each process.
        try Process.mapStacks(kpgtbl);

        return kpgtbl;
    }

    /// Initialize the one kernel_page_table
    pub fn init() void {
        kernel_page_table = kvm.make() catch unreachable;
        log.info("Virtual memory initialized", .{});
    }

    /// Switch h/w page table register to the kernel's page table,
    /// and enable paging.
    pub fn initHardwareThread() void {
        // wait for any previous writes to the page table memory to finish.
        riscv.sfenceVma();

        riscv.satp.write(riscv.makeSatp(kernel_page_table));

        // flush stale entries from the TLB.
        riscv.sfenceVma();
    }

    /// add a mapping to the kernel page table.
    /// only used when booting.
    /// does not flush TLB or enable paging.
    pub fn map(
        kpgtbl: riscv.PageTable,
        virt_addr: u64,
        phy_addr: u64,
        size: u64,
        permission: u64,
    ) void {
        mapPages(
            kpgtbl,
            virt_addr,
            size,
            phy_addr,
            permission,
        ) catch unreachable;
    }

    /// Copy from user to kernel.
    /// Copy len bytes to dst from virtual address srcva in a given page table.
    pub fn copyFromUser(
        page_table: riscv.PageTable,
        dst: [*]u8,
        src_virt_addr: u64,
        len: u64,
    ) !void {
        var remain = len;
        var dst_anchor = dst;
        var va_anchor = src_virt_addr;

        while (remain > 0) {
            const virt_addr = riscv.pgRoundDown(va_anchor);
            const phy_addr = try walkAddr(
                page_table,
                virt_addr,
            );
            const step: u64 = @min(
                riscv.pg_size - (va_anchor - virt_addr),
                remain,
            );

            utils.memMove(
                dst_anchor,
                @ptrFromInt(phy_addr + (va_anchor - virt_addr)),
                step,
            );

            remain -= step;
            dst_anchor += step;
            va_anchor = virt_addr + riscv.pg_size;
        }
    }

    /// Copy a null-terminated string from user to kernel.
    /// Copy bytes to dst from virtual address srcva in a given page table,
    /// until a '\0', or max.
    pub fn copyCStringFromUser(
        page_table: riscv.PageTable,
        buffer: []u8,
        src_virt_addr: u64,
    ) ![]const u8 {
        var quota = buffer.len;
        var buffer_anchor: usize = 0;
        var va_anchor = src_virt_addr;
        var got_null = false;

        while (!got_null and quota > 0) {
            const virt_addr = riscv.pgRoundDown(va_anchor);
            const phy_addr = try walkAddr(
                page_table,
                virt_addr,
            );

            var step: u64 = @min(
                riscv.pg_size - (va_anchor - virt_addr),
                quota,
            );

            var user_str: [*]u8 = @ptrFromInt(phy_addr + (va_anchor - virt_addr));
            while (step > 0) : ({
                step -= 1;
                quota -= 1;
                user_str += 1;
                buffer_anchor += 1;
            }) {
                if (user_str[0] == 0) {
                    got_null = true;
                    break;
                } else {
                    buffer[buffer_anchor] = user_str[0];
                }
            }

            va_anchor = virt_addr + riscv.pg_size;
        }

        if (!got_null) return Error.NotNullTerminated;
        buffer[buffer_anchor] = 0;
        return buffer[0..buffer_anchor];
    }
};

pub const uvm = struct {
    /// Remove n_pages of mappings starting from va. va must be
    /// page-aligned. The mappings must exist.
    /// Optionally free the physical memory.
    pub fn unmap(
        page_table: riscv.PageTable,
        virt_addr: u64,
        n_pages: u64,
        do_free: bool,
    ) void {
        assert(virt_addr % riscv.pg_size == 0);

        var virt_anchor = virt_addr;
        const virt_last = virt_addr + n_pages * riscv.pg_size;
        while (virt_anchor < virt_last) : (virt_anchor += riscv.pg_size) {
            const pte_ptr = walk(
                page_table,
                virt_anchor,
                false,
            ) catch unreachable;

            // not mapped
            assert(
                pte_ptr.* & @intFromEnum(riscv.PteFlag.v) != 0,
            );
            // not a leaf
            assert(
                riscv.pteFlags(pte_ptr.*) != @intFromEnum(riscv.PteFlag.v),
            );

            if (do_free) {
                const phy_addr = riscv.paFromPte(pte_ptr.*);
                kmem.free(@ptrFromInt(phy_addr));
            }
            pte_ptr.* = 0;
        }
    }

    /// create an empty user page table.
    /// returns error if out of memory.
    pub fn create() !riscv.PageTable {
        const page = try kmem.alloc();
        @memset(page, 0);
        return @ptrCast(page);
    }

    /// Load the user initcode into address 0 of pagetable,
    /// for the very first process.
    pub fn first(page_table: riscv.PageTable, src: []const u8) void {
        assert(src.len <= riscv.pg_size);

        const page = kmem.alloc() catch unreachable;
        errdefer kmem.free(page);
        @memset(page, 0);

        const permission: u64 = @intFromEnum(riscv.PteFlag.w) |
            @intFromEnum(riscv.PteFlag.r) |
            @intFromEnum(riscv.PteFlag.x) |
            @intFromEnum(riscv.PteFlag.u);

        mapPages(
            page_table,
            0,
            riscv.pg_size,
            @intFromPtr(page),
            permission,
        ) catch unreachable;
        utils.memMove(page, src.ptr, src.len);
    }

    /// Allocate PTEs and physical memory to grow process from oldsz to
    /// newsz, which need not be page aligned.  Returns new size or null on error.
    pub fn malloc(
        page_table: riscv.PageTable,
        old_size: u64,
        new_size: u64,
        permission: u64,
    ) !u64 {
        if (new_size < old_size) return old_size;

        const rounded_old_size = riscv.pgRoundUp(old_size);
        var size = rounded_old_size;

        errdefer _ = uvm.dealloc(page_table, size, rounded_old_size);

        const ru_permission = @intFromEnum(riscv.PteFlag.r) |
            @intFromEnum(riscv.PteFlag.u);

        while (size < new_size) : (size += riscv.pg_size) {
            const page = try kmem.alloc();
            errdefer kmem.free(page);
            @memset(page, 0);

            try mapPages(
                page_table,
                size,
                riscv.pg_size,
                @intFromPtr(page),
                ru_permission | permission,
            );
        }
        return new_size;
    }

    /// Deallocate user pages to bring the process size from oldsz to
    /// newsz.  oldsz and newsz need not be page-aligned, nor does newsz
    /// need to be less than oldsz.  oldsz can be larger than the actual
    /// process size.  Returns the new process size.
    pub fn dealloc(
        page_table: riscv.PageTable,
        old_size: u64,
        new_size: u64,
    ) u64 {
        if (new_size >= old_size) return old_size;

        const rounded_old_size = riscv.pgRoundUp(old_size);
        const rounded_new_size = riscv.pgRoundUp(new_size);

        if (rounded_new_size < rounded_old_size) {
            const n_pages = @as(
                u64,
                (rounded_old_size - rounded_new_size) / riscv.pg_size,
            );
            uvm.unmap(
                page_table,
                rounded_new_size,
                n_pages,
                true,
            );
        }

        return new_size;
    }

    /// Free user memory pages,
    /// then free page-table pages.
    pub fn free(page_table: riscv.PageTable, size: u64) void {
        if (size > 0) uvm.unmap(
            page_table,
            0,
            riscv.pgRoundUp(size) / riscv.pg_size,
            true,
        );
        freeWalk(page_table);
    }

    /// Given a parent process's page table, copy
    /// its memory into a child's page table.
    /// Copies both the page table and the
    /// physical memory.
    /// returns true on success, false on failure.
    /// frees any allocated pages on failure.
    pub fn copy(from: riscv.PageTable, to: riscv.PageTable, size: u64) !void {
        var addr: usize = 0;

        while (addr < size) : (addr += riscv.pg_size) {
            const pte = (walk(
                from,
                addr,
                false,
            ) catch unreachable).*;

            // page not exist
            assert(pte & @intFromEnum(riscv.PteFlag.v) != 0);

            const phy_addr = riscv.paFromPte(pte);
            const flags = riscv.pteFlags(pte);

            errdefer uvm.unmap(
                to,
                0,
                addr / riscv.pg_size,
                true,
            );

            const page = try kmem.alloc();
            errdefer kmem.free(page);

            utils.memMove(
                page,
                @ptrFromInt(phy_addr),
                riscv.pg_size,
            );

            try mapPages(
                to,
                addr,
                riscv.pg_size,
                @intFromPtr(page),
                flags,
            );
        }
    }

    /// mark a PTE invalid for user access.
    /// used by exec for the user stack guard page.
    pub fn clear(page_table: riscv.PageTable, virt_addr: u64) void {
        (walk(
            page_table,
            virt_addr,
            false,
        ) catch unreachable).* &= ~@intFromEnum(riscv.PteFlag.u);
    }

    /// Copy from kernel to user.
    /// Copy len bytes from src to virtual address dstva in a given page table.
    pub fn copyFromKernel(
        page_table: riscv.PageTable,
        dst_virt_addr: u64,
        src: [*]const u8,
        len: u64,
    ) !void {
        var remain = len;
        var src_anchor = src;
        var va_anchor = dst_virt_addr;

        var step: u64 = 0;

        while (remain > 0) {
            const virt_addr = riscv.pgRoundDown(va_anchor);
            if (virt_addr >= riscv.max_va) return Error.VAOutOfRange;

            const pte_ptr = try walk(page_table, virt_addr, false);
            const pte = pte_ptr.*;

            if (pte & @intFromEnum(
                riscv.PteFlag.v,
            ) == 0) return Error.PTEFlagNotV;
            if (pte & @intFromEnum(
                riscv.PteFlag.u,
            ) == 0) return Error.PTEFlagNotU;
            if (pte & @intFromEnum(
                riscv.PteFlag.w,
            ) == 0) return Error.PTEFlagNotW;

            const phy_addr = riscv.paFromPte(pte);
            step = @min(
                riscv.pg_size - (va_anchor - virt_addr),
                remain,
            );

            utils.memMove(
                @ptrFromInt(phy_addr + (va_anchor - virt_addr)),
                src_anchor,
                step,
            );

            remain -= step;
            src_anchor += step;
            va_anchor = virt_addr + riscv.pg_size;
        }
    }
};
