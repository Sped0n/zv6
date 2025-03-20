const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mkfs_module = b.addModule("mkfs", .{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    mkfs_module.addIncludePath(b.path("../"));
    mkfs_module.addCSourceFile(.{
        .file = b.path("mkfs.c"),
        .flags = &[_][]const u8{
            "-Wall",
            "-Werror",
        },
    });

    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = mkfs_module,
    });

    b.installArtifact(mkfs);

    const run_cmd = b.addRunArtifact(mkfs);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Make fs image");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
