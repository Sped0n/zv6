const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    // The default target is riscv64, but we also support riscv32
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    } });

    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    kernel_module.addAssemblyFile(b.path("src/asm/entry.S"));
    kernel_module.addAssemblyFile(b.path("src/asm/trampoline.S"));
    kernel_module.addAssemblyFile(b.path("src/asm/kernelvec.S"));
    kernel_module.addAssemblyFile(b.path("src/asm/swtch.S"));

    {
        const kernel = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        kernel.want_lto = true; // for std.fmt.format in printf.zig, format print would crash if want_lto is false
        kernel.setLinkerScript(b.path("src/kernel.ld"));
        kernel.entry = .{ .symbol_name = "_entry" };

        b.installArtifact(kernel);
    }

    {
        // For zls build_on_save
        const exe_check = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        exe_check.want_lto = true; // for std.fmt.format in printf.zig, format print would crash if want_lto is false
        exe_check.setLinkerScript(b.path("src/kernel.ld"));
        exe_check.entry = .{ .symbol_name = "_entry" };

        // some error are lazy, has to run install step so zls can give us feedback
        b.installArtifact(exe_check);

        const check = b.step("check", "Check if foo compiles");
        check.dependOn(&exe_check.step);
    }

    const virtio_args = [_][]const u8{
        "-global",
        "virtio-mmio.force-legacy=false",
        "-drive",
        "file=fs.img,if=none,format=raw,id=x0",
        "-device",
        "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
    };

    const qemu_run_args = [_][]const u8{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-bios",
        "none",
        "-kernel",
        "zig-out/bin/kernel",
        "-m",
        "128M",
        "-cpu",
        "rv64",
        "-smp",
        "2",
        "-nographic",
        "-serial",
        "mon:stdio",
    } ++ virtio_args;

    const qemu_gdb_args = qemu_run_args ++ [_][]const u8{
        // Enable the GDB stub.  The exact option depends on the QEMU version.
        // This uses the newer `-gdb` option. If you have an older QEMU,
        // you might need to use `-s -p <port>` instead.
        "-gdb",
        "tcp::3333",
        "-S", // Freeze CPU at startup
    };

    const run_cmd = b.addSystemCommand(&qemu_run_args);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Start the kernel in qemu");
    run_step.dependOn(&run_cmd.step);

    const run_gdb_cmd = b.addSystemCommand(&qemu_gdb_args);
    run_gdb_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gdb_cmd.addArgs(args);

    const run_gdb_step = b.step("run-gdb", "Start the kernel in qemu with gdb");
    run_gdb_step.dependOn(&run_gdb_cmd.step);
}
