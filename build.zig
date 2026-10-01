const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const spec = b.option([]const u8, "spec", "ITI DSL file embedded and parsed at comptime") orelse "../examples/login.iti";
    const profile = b.option([]const u8, "profile", "Test profile: minimal|standard|data|performance|full") orelse "standard";

    const options = b.addOptions();
    options.addOption([]const u8, "spec", spec);
    options.addOption([]const u8, "profile", profile);

    const exe = b.addExecutable(.{
        .name = "iti",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run an embedded ITI specification");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = unit_tests.run();

    const test_step = b.step("test", "Run ITI unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
