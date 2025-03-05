const builtin = @import("std").builtin;

const Process = @import("process/process.zig");
const Cpu = @import("process/cpu.zig");
const scheduler = @import("process/scheduler.zig");
const console = @import("driver/console.zig");
const plic = @import("driver/plic.zig");
const kmem = @import("memory/kmem.zig");
const vm = @import("memory/vm.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");
const printf = @import("printf.zig");

var started = false;

pub fn main() void {
    if (Cpu.id() == 0) {
        console.init();
        printf.printf("zv6 hello world\n", .{});
        kmem.init();
        vm.kvmInit();
        vm.kvmInitHart();
        Process.init();
        trap.init();
        trap.initHart();
        plic.init();
        plic.initHart();

        printf.printf("hart 0 init\n", .{});

        @atomicStore(
            bool,
            &started,
            true,
            builtin.AtomicOrder.release,
        );
    } else {
        while (@atomicLoad(
            bool,
            &started,
            builtin.AtomicOrder.acquire,
        ) == false) {}
        vm.kvmInitHart();
        trap.initHart();
        plic.initHart();
        const cpuid: u8 = @intCast(Cpu.id());
        printf.printf("hart {d} init\n", .{cpuid});
    }

    scheduler.scheduler();
}
