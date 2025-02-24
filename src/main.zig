const builtin = @import("std").builtin;

const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const Cpu = proc.Cpu;
const console = @import("console.zig");
const printf = @import("printf.zig");
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
        console.init();
        printf.printf("zv6 hello world\n", .{});
        kalloc.init();
        vm.kvmInit();
        vm.kvmInitHart();
        proc.init();

        printf.printf("hart 0 init\n", .{});

        @atomicStore(
            bool,
            &started,
            true,
            builtin.AtomicOrder.release,
        );
        while (true) {}
    } else {
        while (@atomicLoad(
            bool,
            &started,
            builtin.AtomicOrder.acquire,
        ) == false) {}
        vm.kvmInitHart();
        const cpuid: u8 = @intCast(Cpu.cpuId());
        printf.printf("hart {d} init\n", .{cpuid});
        hang();
    }
}
