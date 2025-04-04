const memlayout = @import("../memlayout.zig");
const kmem = @import("../memory/kmem.zig");
const misc = @import("../misc.zig");
const panic = @import("../printf.zig").panic;
const printf = @import("../printf.zig").printf;
const Process = @import("../process/Process.zig");
const riscv = @import("../riscv.zig");

// kernel.ld set this to end of kernel code.
const etext = @extern(*u8, .{ .name = "etext" });

// trampoline.S
const trampoline = @extern(*u8, .{ .name = "trampoline" });

pub const Error = error{
    MapPagesFailed,
    TryWalkIntoInvalidPage,
    PTEFlagNotV,
    PTEFlagNotU,
    PTEFlagNotW,
    VAOutOfRange,
    NotNullTerminated,
};

///kernel page table
var kernel_page_table: riscv.PageTable = undefined;

pub fn kvmMake() !riscv.PageTable {
    const kpgtbl: riscv.PageTable = @ptrCast(@alignCast(try kmem.alloc()));

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
    kvmMap(
        kpgtbl,
        memlayout.uart0,
        memlayout.uart0,
        riscv.pg_size,
        rw_permission,
    );

    // virtio mmio disk interface
    kvmMap(
        kpgtbl,
        memlayout.virtio0,
        memlayout.virtio0,
        riscv.pg_size,
        rw_permission,
    );

    // PLIC
    kvmMap(
        kpgtbl,
        memlayout.plic,
        memlayout.plic,
        0x4000000,
        rw_permission,
    );

    // map kernel text executable and read-only.
    kvmMap(
        kpgtbl,
        memlayout.kernel_base,
        memlayout.kernel_base,
        @intFromPtr(etext) - memlayout.kernel_base,
        rx_permission,
    );

    // map kernel data and physical RAM we'll make use of.
    kvmMap(
        kpgtbl,
        @intFromPtr(etext),
        @intFromPtr(etext),
        memlayout.phy_stop - @intFromPtr(etext),
        rw_permission,
    );

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kvmMap(
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

///Initialize the one kernel_page_table
pub fn kvmInit() void {
    kernel_page_table = kvmMake() catch |e| panic(
        @src(),
        "kvmMake failed with {s}",
        .{@errorName(e)},
    );
}

///Switch h/w page table register to the kernel's page table,
///and enable paging.
pub fn kvmInitHart() void {
    // wait for any previous writes to the page table memory to finish.
    riscv.sfenceVma();

    riscv.satp.write(riscv.makeSatp(kernel_page_table));

    // flush stale entries from the TLB.
    riscv.sfenceVma();
}

///Return the address of the PTE in page table pagetable
///that corresponds to virtual address va.  If alloc is
///true, create any required page-table pages.
//
///The risc-v Sv39 scheme has three levels of page-table
///pages. A page-table page contains 512 64-bit PTEs.
///A 64-bit virtual address is split into five fields:
///  39..63 -- must be zero.
///  30..38 -- 9 bits of level-2 index.
///  21..29 -- 9 bits of level-1 index.
///  12..20 -- 9 bits of level-0 index.
///   0..11 -- 12 bits of byte offset within the page.
pub fn walk(
    page_table: riscv.PageTable,
    virt_addr: u64,
    alloc: bool,
) !*riscv.Pte {
    if (virt_addr > riscv.max_va) panic(
        @src(),
        "va({x}) greater than maxva",
        .{virt_addr},
    );

    var local_page_table = page_table;

    var level: u64 = 2;
    while (level > 0) : (level -= 1) {
        const pte_ptr: *riscv.Pte = &local_page_table[
            riscv.pageTableIdxFromVa(
                level,
                virt_addr,
            )
        ];
        const pte = pte_ptr.*;
        if (pte & @intFromEnum(riscv.PteFlag.v) != 0) {
            local_page_table = @ptrFromInt(riscv.pte2Pa(pte));
        } else {
            if (!alloc) return Error.TryWalkIntoInvalidPage;

            local_page_table = @ptrCast(@alignCast(try kmem.alloc()));

            const mem = @as(
                [*]u8,
                @ptrCast(local_page_table),
            )[0..riscv.pg_size];
            @memset(mem, 0);

            pte_ptr.* = riscv.pa2Pte(
                @intFromPtr(local_page_table),
            ) | @intFromEnum(riscv.PteFlag.v);
        }
    }

    return &local_page_table[riscv.pageTableIdxFromVa(0, virt_addr)];
}

///Look up a virtual address, return the physical address,
///or null if not mapped.
///Can only be used to look up user pages.
pub fn walkAddr(page_table: riscv.PageTable, virt_addr: u64) !u64 {
    if (virt_addr >= riscv.max_va) return Error.VAOutOfRange;

    const pte = (try walk(
        page_table,
        virt_addr,
        false,
    )).*;

    if ((pte & @intFromEnum(riscv.PteFlag.v)) == 0) return Error.PTEFlagNotV;
    if ((pte & @intFromEnum(riscv.PteFlag.u)) == 0) return Error.PTEFlagNotU;

    const phy_addr = riscv.pte2Pa(pte);
    return phy_addr;
}

///add a mapping to the kernel page table.
///only used when booting.
///does not flush TLB or enable paging.
pub fn kvmMap(
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
    ) catch |e| panic(
        @src(),
        "mapPages failed with {s}",
        .{@errorName(e)},
    );
}

///Create PTEs for virtual addresses starting at va that refer to
///physical addresses starting at pa.
///va and size MUST be page-aligned.
///Returns true on success, false if walk() couldn't
///allocate a needed page-table page.
pub fn mapPages(
    page_table: riscv.PageTable,
    virt_addr: u64,
    size: u64,
    phy_addr: u64,
    permission: u64,
) !void {
    if ((virt_addr % riscv.pg_size) != 0) panic(
        @src(),
        "va({x}) not aligned",
        .{virt_addr},
    );

    if ((size % riscv.pg_size) != 0) panic(
        @src(),
        "size({d}) not aligned",
        .{size},
    );

    if (size == 0) panic(
        @src(),
        "size is 0",
        .{},
    );

    var local_virt_addr: u64 = virt_addr;
    var local_phy_addr: u64 = phy_addr;
    const last: u64 = virt_addr + size - riscv.pg_size;

    while (local_virt_addr <= last) : ({
        local_virt_addr += riscv.pg_size;
        local_phy_addr += riscv.pg_size;
    }) {
        const pte_ptr = try walk(
            page_table,
            local_virt_addr,
            true,
        );
        if (pte_ptr.* & @intFromEnum(riscv.PteFlag.v) != 0) {
            panic(
                @src(),
                "remap, current pte flag is {x}",
                .{riscv.pteFlags(pte_ptr.*)},
            );
        }
        pte_ptr.* = riscv.pa2Pte(
            local_phy_addr,
        ) | permission | @intFromEnum(
            riscv.PteFlag.v,
        );
    }
}

///Remove npages of mappings starting from va. va must be
///page-aligned. The mappings must exist.
///Optionally free the physical memory.
pub fn uvmUnmap(
    page_table: riscv.PageTable,
    virt_addr: u64,
    npages: u64,
    free: bool,
) void {
    if (virt_addr % riscv.pg_size != 0) panic(
        @src(),
        "va({x}) not aligned",
        .{virt_addr},
    );

    var local_virt_addr = virt_addr;
    const last = virt_addr + npages * riscv.pg_size;
    while (local_virt_addr < last) : (local_virt_addr += riscv.pg_size) {
        const pte_ptr = walk(
            page_table,
            local_virt_addr,
            false,
        ) catch |e| panic(
            @src(),
            "walk failed with {s}",
            .{@errorName(e)},
        );
        const pte = pte_ptr.*;

        if ((pte & @intFromEnum(
            riscv.PteFlag.v,
        )) == 0) panic(@src(), "not mapped", .{});
        if (riscv.pteFlags(pte) == @intFromEnum(
            riscv.PteFlag.v,
        )) panic(@src(), "not a leaf", .{});

        if (free) {
            const phy_addr = riscv.pte2Pa(pte);
            kmem.free(@ptrFromInt(phy_addr));
        }
        pte_ptr.* = 0;
    }
}

///create an empty user page table.
///returns error if out of memory.
pub fn uvmCreate() !riscv.PageTable {
    const page_table: riscv.PageTable = @ptrCast(@alignCast(try kmem.alloc()));

    const mem = @as([*]u8, @ptrCast(page_table))[0..riscv.pg_size];
    @memset(mem, 0);

    return page_table;
}

///Load the user initcode into address 0 of pagetable,
///for the very first process.
pub fn uvmFirst(page_table: riscv.PageTable, src: []const u8) void {
    if (src.len > riscv.pg_size) panic(
        @src(),
        "more than one page({d})",
        .{src.len},
    );

    const mem_ptr = kmem.alloc() catch {
        panic(@src(), "kalloc failed", .{});
        return;
    };

    const mem = @as([*]u8, @ptrCast(mem_ptr))[0..riscv.pg_size];
    @memset(mem, 0);

    const permission: u64 = @intFromEnum(riscv.PteFlag.w) |
        @intFromEnum(riscv.PteFlag.r) |
        @intFromEnum(riscv.PteFlag.x) |
        @intFromEnum(riscv.PteFlag.u);

    mapPages(
        page_table,
        0,
        riscv.pg_size,
        @intFromPtr(mem_ptr),
        permission,
    ) catch |e| {
        kmem.free(mem_ptr);
        panic(
            @src(),
            "mapPages failed with {s}",
            .{@errorName(e)},
        );
    };
    misc.memMove(mem, src.ptr, src.len);
}

///Allocate PTEs and physical memory to grow process from oldsz to
///newsz, which need not be page aligned.  Returns new size or null on error.
pub fn uvmMalloc(
    page_table: riscv.PageTable,
    old_size: u64,
    new_size: u64,
    permission: u64,
) !u64 {
    if (new_size < old_size) return old_size;

    const local_old_size = riscv.pgRoundUp(old_size);
    var size = local_old_size;
    while (size < new_size) : (size += riscv.pg_size) {
        const mem_ptr = kmem.alloc() catch |e| {
            _ = uvmDealloc(page_table, size, local_old_size);
            return e;
        };

        const mem = @as([*]u8, @ptrCast(mem_ptr))[0..riscv.pg_size];
        @memset(mem, 0);

        const ru_permission = @intFromEnum(riscv.PteFlag.r) |
            @intFromEnum(riscv.PteFlag.u);
        mapPages(
            page_table,
            size,
            riscv.pg_size,
            @intFromPtr(mem_ptr),
            ru_permission | permission,
        ) catch {
            kmem.free(mem_ptr);
            _ = uvmDealloc(page_table, size, old_size);
            return Error.MapPagesFailed;
        };
    }
    return new_size;
}

///Deallocate user pages to bring the process size from oldsz to
///newsz.  oldsz and newsz need not be page-aligned, nor does newsz
///need to be less than oldsz.  oldsz can be larger than the actual
///process size.  Returns the new process size.
pub fn uvmDealloc(
    page_table: riscv.PageTable,
    old_size: u64,
    new_size: u64,
) u64 {
    if (new_size >= old_size) return old_size;

    const rounded_old_size = riscv.pgRoundUp(old_size);
    const rounded_new_size = riscv.pgRoundUp(new_size);

    if (rounded_new_size < rounded_old_size) {
        const npages = @as(
            u64,
            (rounded_old_size - rounded_new_size) / riscv.pg_size,
        );
        uvmUnmap(
            page_table,
            rounded_new_size,
            npages,
            true,
        );
    }

    return new_size;
}

///Recursively free page-table pages.
///All leaf mappings must already have been removed.
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
            const child: riscv.PageTable = @ptrFromInt(riscv.pte2Pa(pte));
            freeWalk(child);
            page_table[i] = 0;
        } else if (pte & v_permission != 0) {
            panic(
                @src(),
                "leaf, current pte flag is {x}",
                .{riscv.pteFlags(pte)},
            );
        }
    }
    kmem.free(@ptrCast(page_table));
}

///Free user memory pages,
///then free page-table pages.
pub fn uvmFree(page_table: riscv.PageTable, size: u64) void {
    if (size > 0) uvmUnmap(
        page_table,
        0,
        riscv.pgRoundUp(size) / riscv.pg_size,
        true,
    );
    freeWalk(page_table);
}

///Given a parent process's page table, copy
///its memory into a child's page table.
///Copies both the page table and the
///physical memory.
///returns true on success, false on failure.
///frees any allocated pages on failure.
pub fn uvmCopy(old: riscv.PageTable, new: riscv.PageTable, size: u64) !void {
    var addr: usize = 0;

    while (addr < size) : (addr += riscv.pg_size) {
        const pte_ptr = walk(
            old,
            addr,
            false,
        ) catch panic(@src(), "pte should exist", .{});

        const pte = pte_ptr.*;
        if (pte & @intFromEnum(riscv.PteFlag.v) == 0) panic(
            @src(),
            "page not present, current pte flag is {x}",
            .{riscv.pteFlags(pte)},
        );
        const phy_addr = riscv.pte2Pa(pte);
        const flags = riscv.pteFlags(pte);

        const mem_ptr = kmem.alloc() catch |e| {
            uvmUnmap(
                new,
                0,
                addr / riscv.pg_size,
                true,
            );
            return e;
        };

        misc.memMove(
            mem_ptr,
            @ptrFromInt(phy_addr),
            riscv.pg_size,
        );

        mapPages(
            new,
            addr,
            riscv.pg_size,
            @intFromPtr(mem_ptr),
            flags,
        ) catch {
            kmem.free(mem_ptr);
            uvmUnmap(
                new,
                0,
                addr / riscv.pg_size,
                true,
            );
            return Error.MapPagesFailed;
        };
    }
}

///mark a PTE invalid for user access.
///used by exec for the user stack guard page.
pub fn uvmClear(page_table: riscv.PageTable, virt_addr: u64) void {
    const pte_ptr = walk(
        page_table,
        virt_addr,
        false,
    ) catch |e| panic(
        @src(),
        "walk failed with {s}",
        .{@errorName(e)},
    );
    pte_ptr.* &= ~@intFromEnum(riscv.PteFlag.u);
}

///Copy from kernel to user.
///Copy len bytes from src to virtual address dstva in a given page table.
pub fn copyOut(
    page_table: riscv.PageTable,
    dst_virt_addr: u64,
    src: [*]const u8,
    len: u64,
) !void {
    var local_len = len;
    var local_src = src;
    var local_dstva = dst_virt_addr;

    while (local_len > 0) {
        const virt_addr = riscv.pgRoundDown(local_dstva);
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

        const phy_addr = riscv.pte2Pa(pte);
        const n: u64 = @min(
            riscv.pg_size - (local_dstva - virt_addr),
            local_len,
        );

        misc.memMove(
            @ptrFromInt(phy_addr + (local_dstva - virt_addr)),
            local_src,
            n,
        );

        local_len -= n;
        local_src += n;
        local_dstva = virt_addr + riscv.pg_size;
    }
}

///Copy from user to kernel.
///Copy len bytes to dst from virtual address srcva in a given page table.
pub fn copyIn(
    page_table: riscv.PageTable,
    dst: [*]u8,
    src_virt_addr: u64,
    len: u64,
) !void {
    var local_len = len;
    var local_dst = dst;
    var local_srcva = src_virt_addr;

    while (local_len > 0) {
        const virt_addr = riscv.pgRoundDown(local_srcva);
        const phy_addr = try walkAddr(
            page_table,
            virt_addr,
        );
        const n: u64 = @min(
            riscv.pg_size - (local_srcva - virt_addr),
            local_len,
        );

        misc.memMove(
            local_dst,
            @ptrFromInt(phy_addr + (local_srcva - virt_addr)),
            n,
        );

        local_len -= n;
        local_dst += n;
        local_srcva = virt_addr + riscv.pg_size;
    }
}

///Copy a null-terminated string from user to kernel.
///Copy bytes to dst from virtual address srcva in a given page table,
///until a '\0', or max.
pub fn copyInStr(
    page_table: riscv.PageTable,
    dst: [*c]u8,
    src_virt_addr: u64,
    max: u64,
) !void {
    var local_max = max;
    var local_dst = dst;
    var local_srcva = src_virt_addr;
    var got_null = false;

    while (!got_null and local_max > 0) {
        const virt_addr = riscv.pgRoundDown(local_srcva);
        const phy_addr = try walkAddr(
            page_table,
            virt_addr,
        );

        var n: u64 = @min(
            riscv.pg_size - (local_srcva - virt_addr),
            local_max,
        );

        var p: [*]u8 = @ptrFromInt(phy_addr + (local_srcva - virt_addr));
        while (n > 0) : ({
            n -= 1;
            local_max -= 1;
            p += 1;
            local_dst += 1;
        }) {
            if (p[0] == 0) {
                local_dst[0] = 0;
                got_null = true;
                break;
            } else {
                local_dst[0] = p[0];
            }
        }

        local_srcva = virt_addr + riscv.pg_size;
    }

    if (!got_null) return Error.NotNullTerminated;
}
