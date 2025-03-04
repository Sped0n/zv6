const builtin = @import("std").builtin;

const riscv = @import("riscv.zig");
const Proc = @import("proc/proc.zig");
const Cpu = @import("proc/cpu.zig");
const scheduler = @import("proc/scheduler.zig");
const console = @import("console.zig");
const printf = @import("printf.zig");
const kmem = @import("kmem.zig");
const vm = @import("vm.zig");
const trap = @import("trap.zig");
const plic = @import("plic.zig");

var started = false;

pub fn main() void {
    if (Cpu.id() == 0) {
        console.init();
        printf.printf("zv6 hello world\n", .{});
        kmem.init();
        vm.kvmInit();
        vm.kvmInitHart();
        Proc.init();
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
