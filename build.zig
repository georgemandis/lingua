const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for NLP core logic
    const nlp_mod = b.createModule(.{
        .root_source_file = b.path("src/nlp.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target_os == .macos) {
        nlp_mod.linkSystemLibrary("objc", .{});
        nlp_mod.linkFramework("Foundation", .{});
        nlp_mod.linkFramework("NaturalLanguage", .{});
    }

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "lingua",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nlp", .module = nlp_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the lingua CLI");
    run_step.dependOn(&run_cmd.step);
}
