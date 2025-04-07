const builtin = @import("std").builtin;

const console = @import("driver/console.zig");
const plic = @import("driver/plic.zig");
const kmem = @import("memory/kmem.zig");
const vm = @import("memory/vm.zig");
const printf = @import("printf.zig");
const Cpu = @import("process/Cpu.zig");
const Process = @import("process/Process.zig");
const scheduler = @import("process/scheduler.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");
const Buf = @import("fs/Buf.zig");
const Inode = @import("fs/Inode.zig");
const File = @import("fs/File.zig");
const virtio_disk = @import("driver/virtio_disk.zig");

var started = false;

pub fn main() callconv(.c) void {
    if (Cpu.id() == 0) {
        console.init();
        printf.init();
        printf.printf("{{zv6}} {s}\n", .{"hello world"});
        kmem.init();
        vm.kvmInit();
        vm.kvmInitHart();
        Process.init();
        trap.init();
        trap.initHart();
        plic.init();
        plic.initHart();
        Buf.init();
        Inode.init();
        File.init();
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
        vm.kvmInitHart();
        trap.initHart();
        plic.initHart();
        const cpuid: u8 = @intCast(Cpu.id());
        printf.printf("hart {d} init\n", .{cpuid});
    }

    scheduler.scheduler();
}
