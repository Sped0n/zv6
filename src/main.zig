const builtin = @import("std").builtin;
const fmt = @import("std").fmt;

const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const Cpu = proc.Cpu;
const uart = @import("uart.zig");
const kalloc = @import("kalloc.zig");
const vm = @import("vm.zig");

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
        kalloc.init();
        vm.kvmInit();
        proc.init();

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
