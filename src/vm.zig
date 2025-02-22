const riscv = @import("riscv.zig");
const kalloc = @import("kalloc.zig");
const memlayout = @import("memlayout.zig");
const proc = @import("proc.zig");
const panic = @import("uart.zig").dumbPanic;

///kernel page table
var kernel_page_table: riscv.PageTable = undefined;

///kernel.ld set this to end of kernel code.
const etext: *anyopaque = @ptrCast(@extern(
    [*c]c_char,
    .{ .name = "etext" },
));

///trampoline.S
const trampoline: *anyopaque = @ptrCast(@extern(
    [*c]c_char,
    .{ .name = "trampoline" },
));

pub fn kvmMake() riscv.PageTable {
    const kpgtbl: riscv.PageTable = @alignCast(@ptrCast(kalloc.kalloc()));

    @memset(kpgtbl, 0);
    const rw_permission: usize = @intFromEnum(
        riscv.PteFlag.r,
    ) | @intFromEnum(
        riscv.PteFlag.w,
    );
    const rx_permission: usize = @intFromEnum(
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
        0x400000,
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
    proc.mapStacks(kpgtbl);

    return kpgtbl;
}

pub fn kvmInit() void {
    kernel_page_table = kvmMake();
}

// Return the address of the PTE in page table pagetable
// that corresponds to virtual address va.  If alloc!=0,
// create any required page-table pages.
//
// The risc-v Sv39 scheme has three levels of page-table
// pages. A page-table page contains 512 64-bit PTEs.
// A 64-bit virtual address is split into five fields:
//   39..63 -- must be zero.
//   30..38 -- 9 bits of level-2 index.
//   21..29 -- 9 bits of level-1 index.
//   12..20 -- 9 bits of level-0 index.
//    0..11 -- 12 bits of byte offset within the page.
pub fn walk(
    page_table: riscv.PageTable,
    virt_addr: usize,
    alloc: bool,
) ?*riscv.Pte {
    if (virt_addr > riscv.maxva) panic("walk va greater than maxva");

    var curr_page_table = page_table;

    var level: usize = 2;
    while (level > 0) : (level -= 1) {
        const pte_p: *riscv.Pte = &page_table[
            riscv.px(
                level,
                virt_addr,
            )
        ];
        const pte = pte_p.*;
        if (pte & @intFromEnum(riscv.PteFlag.v) != 0) {
            curr_page_table = @ptrFromInt(riscv.pte2Pa(pte));
        } else {
            if (!alloc) return null;
            curr_page_table = @alignCast(@ptrCast(kalloc.kalloc() orelse {
                panic("walk kalloc failed");
                return null;
            }));

            @memset(curr_page_table, 0);

            pte_p.* = riscv.pa2Pte(
                @intFromPtr(curr_page_table),
            ) | @intFromEnum(riscv.PteFlag.v);
        }
    }

    return &curr_page_table[riscv.px(0, virt_addr)];
}

///add a mapping to the kernel page table.
///only used when booting.
///does not flush TLB or enable paging.
pub fn kvmMap(
    kpgtbl: riscv.PageTable,
    virt_addr: usize,
    phy_addr: usize,
    size: usize,
    permission: usize,
) void {
    if (!mapPages(
        kpgtbl,
        virt_addr,
        size,
        phy_addr,
        permission,
    )) panic("kvmmap failed");
}

///Create PTEs for virtual addresses starting at va that refer to
///physical addresses starting at pa.
///va and size MUST be page-aligned.
///Returns 0 on success, -1 if walk() couldn't
///allocate a needed page-table page.
pub fn mapPages(
    page_table: riscv.PageTable,
    virt_addr: usize,
    size: usize,
    phy_addr: usize,
    permission: usize,
) bool {
    if ((virt_addr % riscv.pg_size) != 0) panic("mappages: va not aligned");

    if ((size % riscv.pg_size) != 0) panic("mappages: size not aligned");

    if (size == 0) panic("mappages: size is 0");

    var curr_virt_addr: usize = virt_addr;
    var curr_phy_addr: usize = phy_addr;
    const last: usize = virt_addr + size - riscv.pg_size;

    while (curr_virt_addr < last) : ({
        curr_virt_addr += riscv.pg_size;
        curr_phy_addr += riscv.pg_size;
    }) {
        if (walk(
            page_table,
            curr_virt_addr,
            true,
        )) |pte_p| {
            if (pte_p.* & @intFromEnum(riscv.PteFlag.v) != 0) {
                panic("mappages: remap");
            }
            pte_p.* = riscv.pa2Pte(
                curr_phy_addr,
            ) | permission | @intFromEnum(
                riscv.PteFlag.v,
            );
        } else {
            return false;
        }
    }

    return true;
}
