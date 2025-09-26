const builtin = @import("std").builtin;

const console = @import("driver/console.zig");
const plic = @import("driver/plic.zig");
const virtio_disk = @import("driver/virtio_disk.zig");
const fs = @import("fs/fs.zig");
const kmem = @import("memory/kmem.zig");
const vm = @import("memory/vm.zig");
const printf = @import("printf.zig");
const Cpu = @import("process/Cpu.zig");
const Process = @import("process/Process.zig");
const scheduler = @import("process/scheduler.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");

var started = false;

pub fn main() callconv(.c) void {
    if (Cpu.id() == 0) {
        console.init();
        printf.init();
        printf.printf("{{zv6}} {s}\n", .{"hello world"});
        kmem.init();
        vm.kvm.init();
        vm.kvm.initHardwareThread();
        Process.init();
        trap.init();
        trap.initHardwareThread();
        plic.init();
        plic.initHardwareThread();
        fs.Buffer.init();
        fs.Inode.init();
        fs.File.init();
        virtio_disk.init();
        Process.userInit();

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
        vm.kvm.initHardwareThread();
        trap.initHardwareThread();
        plic.initHardwareThread();
        const cpuid: u8 = @intCast(Cpu.id());
        printf.printf("hart {d} init\n", .{cpuid});
    }

    scheduler.scheduler();
}
