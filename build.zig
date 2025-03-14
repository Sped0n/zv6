const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    // The default target is riscv64, but we also support riscv32
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    } });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    kernel.setLinkerScript(b.path("src/kernel.ld"));
    kernel.addAssemblyFile(b.path("src/asm/entry.S"));
    kernel.addAssemblyFile(b.path("src/asm/trampoline.S"));
    kernel.addAssemblyFile(b.path("src/asm/kernelvec.S"));
    kernel.addAssemblyFile(b.path("src/asm/swtch.S"));
    kernel.entry = .{ .symbol_name = "_entry" };

    b.installArtifact(kernel);

    // For zls build_on_save
    const exe_check = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    exe_check.setLinkerScript(b.path("src/kernel.ld"));
    exe_check.addAssemblyFile(b.path("src/asm/entry.S"));
    exe_check.addAssemblyFile(b.path("src/asm/trampoline.S"));
    exe_check.addAssemblyFile(b.path("src/asm/kernelvec.S"));
    exe_check.addAssemblyFile(b.path("src/asm/swtch.S"));
    exe_check.entry = .{ .symbol_name = "_entry" };

    //  try to generate a unique GDB port
    const GDBPORT = 3333;

    const qemu_run_args = &.{
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
    };

    const qemu_gdb_args = &.{
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
        "4",
        "-nographic",
        // Enable the GDB stub.  The exact option depends on the QEMU version.
        // This uses the newer `-gdb` option. If you have an older QEMU,
        // you might need to use `-s -p <port>` instead.
        "-gdb",
        std.fmt.allocPrint(b.allocator, "tcp::{}", .{GDBPORT}) catch unreachable,
        "-S", // Freeze CPU at startup
        "-serial",
        "mon:stdio",
    };

    const run_cmd = b.addSystemCommand(qemu_run_args);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Start the kernel in qemu");
    run_step.dependOn(&run_cmd.step);

    const run_gdb_cmd = b.addSystemCommand(qemu_gdb_args);
    run_gdb_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gdb_cmd.addArgs(args);

    const run_gdb_step = b.step("run-gdb", "Start the kernel in qemu with gdb");
    run_gdb_step.dependOn(&run_gdb_cmd.step);

    // For zls build_on_save
    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&exe_check.step);
}
