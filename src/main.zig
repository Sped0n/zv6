const builtin = @import("std").builtin;
const fmt = @import("std").fmt;

const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const Cpu = proc.Cpu;
const uart = @import("uart.zig");

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
        const hello_str: []const u8 = "zv6 hello world\n";
        for (hello_str) |c| {
            uart.putCharSync(c);
        }
        @atomicStore(
            bool,
            &started,
            true,
            builtin.AtomicOrder.release,
        );
        const echo_str: []const u8 = "not impl\n";
        while (true) {
            if (uart.getChar()) |_| {
                for (echo_str) |c| {
                    uart.putCharSync(c);
                }
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
