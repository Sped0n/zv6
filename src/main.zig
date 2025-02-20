const builtin = @import("std").builtin;
const fmt = @import("std").fmt;

const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const Cpu = proc.Cpu;
const uart = @import("uart.zig");
const kalloc = @import("kalloc.zig");

var started = false;

comptime {
    asm (
        \\.global hang
        \\
        \\hang:
        \\    wfi  # Wait For Interrupt
        \\    j hang # Jump back to wfi
    );
}

extern fn hang() void;

pub fn main() void {
    if (Cpu.cpuId() == 0) {
        uart.dumbPrint("zv6 hello world");
        kalloc.kinit();

        // Test 2: Allocate a page
        const page1 = kalloc.kalloc();
        uart.dumbAssert(page1 != null, "page1 != null");

        // Test 3: Allocate another page
        const page2 = kalloc.kalloc();
        uart.dumbAssert(page2 != null, "page2 != null");
        uart.dumbAssert(page1 != page2, "page1 != page2");

        // Test 4: Free a page and reallocate
        kalloc.kfree(page1.?);
        const page3 = kalloc.kalloc();
        uart.dumbAssert(page3 != null, "page3 != null");
        uart.dumbAssert(page1 == page3, "page1 == page3");

        // Test 5: Try to free invalid address
        //kalloc.kfree(@ptrFromInt(0x1000)); // Should not crash, just return

        // Test 6: Try to free unaligned address
        //kalloc.kfree(@ptrFromInt(0x1001)); // Should not crash, just return

        uart.dumbPrint("All tests passed!");

        @atomicStore(
            bool,
            &started,
            true,
            builtin.AtomicOrder.release,
        );
        while (true) {
            if (uart.getChar()) |_| {
                uart.dumbPrint("not impl");
            }
        }
    } else {
        while (@atomicLoad(
            bool,
            &started,
            builtin.AtomicOrder.acquire,
        ) == false) {}
        const cpuid: u8 = @intCast(Cpu.cpuId());
        uart.putCharSync('0' + cpuid);
        hang();
    }
}
