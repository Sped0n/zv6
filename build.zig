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
    "zig-out/kernel/kernel",
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

const qemu_trace_args = qemu_gdb_args ++ [_][]const u8{
    "-D",
    "qemu_debug.log",
    "-d",
    "guest_errors,int,in_asm",
};

const cflags = [_][]const u8{
    "-Wall",
    "-Werror",
    "-O",
    "-fno-omit-frame-pointer",
    "-ggdb",
    "-gdwarf-2",
    "-MD",
    "-mcmodel=medany",
    "-fno-common",
    "-nostdlib",
    "-mno-relax",
    "-fno-builtin-strncpy",
    "-fno-builtin-strncmp",
    "-fno-builtin-memset",
    "-fno-builtin-memmove",
    "-fno-builtin-memcmp",
    "-fno-builtin-log",
    "-fno-builtin-bzero",
    "-fno-builtin-strchr",
    "-fno-builtin-exit",
    "-fno-builtin-malloc",
    "-fno-builtin-putc",
    "-fno-builtin-free",
    "-fno-builtin-memcpy",
    "-Wno-main",
    "-fno-builtin-prtinf",
    "-fno-builtin-fprintf",
    "-fno-builtin-vprintf",
};

const user_progs = [_][]const u8{
    "cat",
    "echo",
    "forktest",
    "grep",
    "init",
    "kill",
    "ln",
    "ls",
    "mkdir",
    "rm",
    "sh",
    "stressfs",
    "usertests",
    "grind",
    "wc",
    "zombie",
};

pub fn build(b: *std.Build) void {
    const keep_fsimg = b.option(bool, "keep-fsimg", "Keep the existing fs.img instead of recreating it") orelse false;

    const optimize = b.standardOptimizeOption(.{});
    const native = b.standardTargetOptions(.{});
    const rv64 = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // step --------------------------------------------------------------------
    const build_mkfs_step = b.step(
        "mkfs",
        "Build mkfs binary",
    );

    const gen_usys_step = b.step("gen-usys", "Generate usys.S");
    const build_user_step = b.step(
        "user",
        "Build user programs",
    );

    const rm_image_step = b.step(
        "rm-image",
        "Remove existing fs.img",
    );
    const create_image_step = b.step(
        "image",
        "Create fs image",
    );

    const gen_initcode_step = b.step("initcode", "Generate initcode binary");

    const build_kernel_step = b.step(
        "kernel",
        "Build kernel",
    );
    const run_kernel_step = b.step(
        "qemu",
        "Start the kernel in qemu",
    );
    const debug_kernel_step = b.step(
        "qemu-gdb",
        "Start the kernel in qemu with gdb",
    );
    const trace_kernel_step = b.step(
        "qemu-trace",
        "Start the kernel in qemu with gdb and trace log enabled",
    );

    const check = b.step(
        "check",
        "Check if foo compiles",
    );

    // mkfs ------------------------------------------------------------------
    const mkfs_module = b.createModule(.{
        .root_source_file = null,
        .target = native,
        .optimize = .ReleaseFast,
        .link_libc = true,
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

        const build_cmd = b.addInstallArtifact(
            mkfs,
            .{
                .dest_dir = .{
                    .override = .{ .custom = "mkfs" },
                },
            },
        );
        build_mkfs_step.dependOn(&build_cmd.step);
    }

    // usys --------------------------------------------------------------------
    const gen_usys_cmd = b.addSystemCommand(&[_][]const u8{
        "perl",
        "user/usys.pl",
    });
    gen_usys_cmd.setCwd(b.path("."));
    gen_usys_step.dependOn(
        &b.addInstallFile(
            gen_usys_cmd.captureStdOut(),
            "../user/usys.S",
        ).step,
    );
    build_user_step.dependOn(gen_usys_step);

    // user programs -----------------------------------------------------------
    const ulib_module = b.createModule(.{
        .root_source_file = null,
        .target = rv64,
        .optimize = .ReleaseSmall,
        .code_model = .medium,
    });
    ulib_module.addIncludePath(b.path("."));
    ulib_module.addCSourceFile(.{
        .file = b.path("user/ulib.c"),
        .flags = &cflags,
    });
    ulib_module.addCSourceFile(.{
        .file = b.path("user/printf.c"),
        .flags = &cflags,
    });
    ulib_module.addCSourceFile(.{
        .file = b.path("user/umalloc.c"),
        .flags = &cflags,
    });
    ulib_module.addAssemblyFile(b.path("user/usys.S"));

    {
        const ulib = b.addStaticLibrary(.{
            .name = "ulib",
            .root_module = ulib_module,
        });

        for (user_progs) |prog_name| {
            const prog_module = b.createModule(.{
                .root_source_file = null,
                .target = rv64,
                .optimize = .ReleaseSmall,
                .code_model = .medium,
            });
            prog_module.linkLibrary(ulib);
            prog_module.addIncludePath(b.path("."));
            prog_module.addCSourceFile(.{
                .file = b.path(std.mem.concat(
                    b.allocator,
                    u8,
                    &[_][]const u8{ "user/", prog_name, ".c" },
                ) catch unreachable),
                .flags = &cflags,
            });

            const prog = b.addExecutable(.{
                .name = std.mem.concat(
                    b.allocator,
                    u8,
                    &[_][]const u8{ "_", prog_name },
                ) catch unreachable,
                .root_module = prog_module,
            });
            prog.setLinkerScript(b.path("user/user.ld"));
            prog.link_z_max_page_size = 4096;
            prog.entry = .{ .symbol_name = "main" };
            prog.link_function_sections = true;
            prog.link_data_sections = true;
            prog.link_gc_sections = true;

            build_user_step.dependOn(&b.addInstallArtifact(
                prog,
                .{
                    .dest_dir = .{
                        .override = .{ .custom = "user" },
                    },
                },
            ).step);
        }
    }

    // fs.img ------------------------------------------------------------------
    {
        const rm_image_cmd = b.addSystemCommand(&.{ "rm", "-f", "fs.img" });
        rm_image_cmd.setCwd(b.path("."));
        rm_image_step.dependOn(&rm_image_cmd.step);
    }
    {
        var prog_paths = std.ArrayList([]const u8).init(b.allocator);
        for (user_progs) |prog_name| prog_paths.append(
            std.mem.concat(
                b.allocator,
                u8,
                &[_][]const u8{ "zig-out/user/", "_", prog_name },
            ) catch unreachable,
        ) catch unreachable;

        const create_image_cmd = b.addSystemCommand(&[_][]const u8{
            "zig-out/mkfs/mkfs",
            "fs.img",
            "misc/README",
        });
        create_image_cmd.setCwd(b.path("."));
        create_image_cmd.addArgs(prog_paths.items);
        create_image_cmd.step.dependOn(rm_image_step);
        create_image_cmd.step.dependOn(build_mkfs_step);
        create_image_cmd.step.dependOn(build_user_step);
        create_image_step.dependOn(&create_image_cmd.step);
    }

    // initcode ----------------------------------------------------------------
    const initcode_object = b.addObject(.{
        .name = "initcode",
        .root_source_file = null,
        .target = rv64,
        .optimize = optimize,
    });
    initcode_object.addAssemblyFile(b.path("user/initcode.S"));
    initcode_object.addIncludePath(b.path("."));
    initcode_object.link_z_max_page_size = 4096;
    initcode_object.entry = .{ .symbol_name = "start" };
    const initcode_bin = b.addObjCopy(
        initcode_object.getEmittedBin(),
        .{ .format = .bin },
    );
    gen_initcode_step.dependOn(&b.addInstallBinFile(
        initcode_bin.getOutput(),
        "user/initcode",
    ).step);

    // kernel ------------------------------------------------------------------
    const kernel_module = b.addModule("kernel", .{
        .root_source_file = b.path("kernel/start.zig"),
        .target = rv64,
        .optimize = optimize,
        .code_model = .medium,
        .omit_frame_pointer = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
    });
    kernel_module.addAssemblyFile(b.path("kernel/asm/entry.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/trampoline.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/kernelvec.S"));
    kernel_module.addAssemblyFile(b.path("kernel/asm/swtch.S"));
    kernel_module.addAnonymousImport("initcode", .{
        .root_source_file = initcode_bin.getOutput(),
    });

    {
        const kernel = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        kernel.setLinkerScript(b.path("kernel/kernel.ld"));
        kernel.link_z_max_page_size = 4096;
        kernel.link_function_sections = true;
        kernel.link_data_sections = true;
        kernel.link_gc_sections = true;
        kernel.entry = .{ .symbol_name = "_entry" };

        const build_cmd = b.addInstallArtifact(
            kernel,
            .{
                .dest_dir = .{
                    .override = .{ .custom = "kernel" },
                },
            },
        );
        build_cmd.step.dependOn(gen_initcode_step);
        build_kernel_step.dependOn(&build_cmd.step);

        const run_cmd = b.addSystemCommand(&qemu_run_args);
        if (!keep_fsimg) {
            run_cmd.step.dependOn(create_image_step);
        }
        run_cmd.step.dependOn(build_kernel_step);
        run_kernel_step.dependOn(&run_cmd.step);

        const debug_cmd = b.addSystemCommand(&qemu_gdb_args);
        if (!keep_fsimg) {
            debug_cmd.step.dependOn(create_image_step);
        }
        debug_cmd.step.dependOn(build_kernel_step);
        debug_kernel_step.dependOn(&debug_cmd.step);

        const trace_cmd = b.addSystemCommand(&qemu_trace_args);
        if (!keep_fsimg) {
            trace_cmd.step.dependOn(create_image_step);
        }
        trace_cmd.step.dependOn(build_kernel_step);
        trace_kernel_step.dependOn(&trace_cmd.step);
    }

    // zls build-on-save
    {
        const exe_check = b.addExecutable(.{
            .name = "kernel",
            .root_module = kernel_module,
            .linkage = .static,
        });
        exe_check.setLinkerScript(b.path("kernel/kernel.ld"));
        exe_check.link_z_max_page_size = 4096;
        exe_check.link_function_sections = true;
        exe_check.link_data_sections = true;
        exe_check.link_gc_sections = true;
        exe_check.entry = .{ .symbol_name = "_entry" };

        // some error are lazy, has to run install step so zls can give us feedback
        b.installArtifact(exe_check);

        check.dependOn(&exe_check.step);
    }
}
