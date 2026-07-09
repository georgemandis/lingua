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

    // Cross-compilation SDK paths (e.g. -Dtarget=x86_64-macos on aarch64 host)
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!is_native and target_os == .macos) {
        const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");
        if (macos_sdk) |sdk| {
            nlp_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            nlp_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    if (target_os == .macos) {
        nlp_mod.linkSystemLibrary("objc", .{});
        nlp_mod.linkFramework("Foundation", .{});
        nlp_mod.linkFramework("NaturalLanguage", .{});
        nlp_mod.linkFramework("AppKit", .{});
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

    // Unit tests (src/lsp.zig)
    const lsp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nlp", .module = nlp_mod },
            },
        }),
    });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lsp_tests.step);
}
