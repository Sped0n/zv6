const std = @import("std");

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

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // step --------------------------------------------------------------------
    const mkfs_build_step = b.step(
        "mkfs",
        "Build mkfs binary",
    );
    const mkfs_run_step = b.step(
        "mkfs-run",
        "Make fs image",
    );

    const kernel_build_step = b.step(
        "kernel",
        "Build kernel",
    );
    const kernel_run_step = b.step(
        "qemu",
        "Start the kernel in qemu",
    );
    const kernel_run_gdb_step = b.step(
        "qemu-gdb",
        "Start the kernel in qemu with gdb",
    );

    const check = b.step(
        "check",
        "Check if foo compiles",
    );

    // mkfs ------------------------------------------------------------------
    const mkfs_module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    mkfs_module.addIncludePath(b.path("."));
    mkfs_module.addCSourceFile(.{
        .file = b.path("mkfs/mkfs.c"),
        .flags = &[_][]const u8{
            "-Wall",
            "-Werror",
        },
    });

    {
        const mkfs = b.addExecutable(.{
            .name = "mkfs",
            .root_module = mkfs_module,
        });

        const build_cmd = b.addInstallArtifact(mkfs, .{});
        mkfs_build_step.dependOn(&build_cmd.step);

        const run_cmd = b.addRunArtifact(mkfs);
        run_cmd.step.dependOn(mkfs_build_step);
        mkfs_run_step.dependOn(&run_cmd.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    // kernel ------------------------------------------------------------------
    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("kernel/start.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = optimize,
        .code_model = .medium,
    });
    kernel_module.addAssemblyFile(b.path("kernel/asm/entry.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/trampoline.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/kernelvec.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/swtch.S"));

    {
        const kernel = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        // for std.fmt.format would crash if want_lto is false
        kernel.want_lto = true;
        kernel.setLinkerScript(b.path("kernel/kernel.ld"));
        kernel.entry = .{ .symbol_name = "_entry" };

        const build_cmd = b.addInstallArtifact(kernel, .{});
        kernel_build_step.dependOn(&build_cmd.step);

        const run_cmd = b.addSystemCommand(&qemu_run_args);
        run_cmd.step.dependOn(kernel_build_step);
        if (b.args) |args| run_cmd.addArgs(args);

        kernel_run_step.dependOn(&run_cmd.step);

        const run_gdb_cmd = b.addSystemCommand(&qemu_gdb_args);
        run_gdb_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_gdb_cmd.addArgs(args);

        kernel_run_gdb_step.dependOn(&run_gdb_cmd.step);
    }

    // zls build-on-save
    {
        const exe_check = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        // for std.fmt.format would crash if want_lto is false
        exe_check.want_lto = true;
        exe_check.setLinkerScript(b.path("src/kernel.ld"));
        exe_check.entry = .{ .symbol_name = "_entry" };

        // some error are lazy, has to run install step so zls can give us feedback
        b.installArtifact(exe_check);

        check.dependOn(&exe_check.step);
    }
}
