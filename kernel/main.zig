const std = @import("std");
const builtin = std.builtin;

const console = @import("console.zig");
const diag = @import("diag.zig");
const plic = @import("driver/plic.zig");
const virtio_disk = @import("driver/virtio_disk.zig");
const fs = @import("fs/fs.zig");
const kmem = @import("memory/kmem.zig");
const vm = @import("memory/vm.zig");
const Cpu = @import("process/Cpu.zig");
const Process = @import("process/Process.zig");
const scheduler = @import("process/scheduler.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");

const log = std.log.scoped(.main);

var started = false;

pub fn main() callconv(.c) void {
    const cpu_id = Cpu.id();
    if (cpu_id == 0) {
        console.init();
        diag.init();
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

        log.info("Hardware thread {d} started", .{cpu_id});

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
        log.info("Hardware thread {d} started", .{cpu_id});
    }

    scheduler.scheduler();
}
