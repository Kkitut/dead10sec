const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("include"));

    const c_mod = translate_c.createModule();

    const exe = b.addExecutable(.{
        .name = "dead10sec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("c", c_mod);
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/stb_impl.c") });

    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        exe.root_module.addLibraryPath(b.path("lib/win64"));
        exe.root_module.linkSystemLibrary("glfw3", .{});
        exe.root_module.linkSystemLibrary("vulkan-1", .{});
    } else {
        exe.root_module.addLibraryPath(b.path("lib"));
        exe.root_module.linkSystemLibrary("glfw3", .{});
        exe.root_module.linkSystemLibrary("vulkan", .{});
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run dead10sec");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}
