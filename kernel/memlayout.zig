// Physical memory layout

// qemu -machine virt is set up like this,
// based on qemu's hw/riscv/virt.c:

// 00001000 -- boot ROM, provided by qemu
// 02000000 -- CLINT
// 0C000000 -- PLIC
// 10000000 -- uart0
// 10001000 -- virtio disk
// 80000000 -- boot ROM jumps here in machine mode
//             -kernel loads the kernel here
// unused RAM after 80000000.

// the kernel uses physical memory thus:
// 80000000 -- entry.S, then kernel text and data
// end -- start of kernel page allocation area
// PHYSTOP -- end RAM used by the kernel

const riscv = @import("riscv.zig");
// qemu puts UART registers here in physical memory.
pub const uart0 = 0x10000000;
pub const uart0_irq = 10;

// virtio mmio interface
pub const virtio0 = 0x10001000;
pub const virtio0_irq = 1;

// core local interruptor (CLINT), which contains the timer.
pub const clint = 0x2000000;
pub inline fn clintMtimecmp(hartid: u64) *u64 {
    return @ptrFromInt(clint + 0x4000 + 8 * hartid);
}
// cycles since boot.
pub const clint_mtime: *u64 = @ptrFromInt(clint + 0xBFF8);

// qemu puts platform-level interrupt controller (PLIC) here.
pub const plic = 0x0c000000;
pub const plic_priority = plic + 0x0;
pub const plic_pending = plic + 0x1000;
pub inline fn plicMEnable(hart: u64) u64 {
    return plic + 0x2000 + hart * 0x100;
}
pub inline fn plicSEnable(hart: u64) u64 {
    return plic + 0x2080 + hart * 0x100;
}
pub inline fn plicMPriority(hart: u64) u64 {
    return plic + 0x200000 + hart * 0x2000;
}
pub inline fn plicSPriority(hart: u64) u64 {
    return plic + 0x201000 + hart * 0x2000;
}
pub inline fn plicMClaim(hart: u64) u64 {
    return plic + 0x200004 + hart * 0x2000;
}
pub inline fn plicSClaim(hart: u64) u64 {
    return plic + 0x201004 + hart * 0x2000;
}

// the kernel expects there to be RAM
// for use by the kernel and user pages
// from physical address 0x80000000 to PHYSTOP.
pub const kernel_base = 0x80000000;
pub const phy_stop = kernel_base + 128 * 1024 * 1024;

// map the trampoline page to the highest address,
// in both user and kernel space.
pub const trampoline: u64 = riscv.max_va - @as(u64, riscv.pg_size);

///map kernel stacks beneath the trampoline,
///each surrounded by invalid guard pages.
pub inline fn kernelStack(proc_index: u64) u64 {
    return trampoline - (proc_index + 1) * 2 * riscv.pg_size;
}

// User memory layout.
// Address zero first:
//   text
//   original data and bss
//   fixed-size stack
//   expandable heap
//   ...
//   TRAPFRAME (p->trapframe, used by the trampoline)
//   TRAMPOLINE (the same page as in the kernel)
pub const trap_frame: u64 = trampoline - riscv.pg_size;
