const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const spec = b.option([]const u8, "spec", "ITI DSL file embedded and parsed at comptime") orelse "examples/login.iti";
    const profile = b.option([]const u8, "profile", "Test profile: minimal|standard|data|performance|full") orelse "standard";
    const ui = b.option([]const u8, "ui", "Output projection: ndjson|tui") orelse "tui";

    const options = b.addOptions();
    options.addOption([]const u8, "spec", spec);
    options.addOption([]const u8, "profile", profile);
    options.addOption([]const u8, "ui", ui);

    const tui_dep = b.dependency("tui", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "iti",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("tui", tui_dep.module("tui"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run an embedded ITI specification");
    run_step.dependOn(&run_cmd.step);

    // ITI Test Dashboard TUI (issue #5): `zig build dashboard`.
    const dash_exe = b.addExecutable(.{
        .name = "iti-dashboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dashboard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dash_exe.root_module.addOptions("build_options", options);
    dash_exe.root_module.addImport("tui", tui_dep.module("tui"));
    b.installArtifact(dash_exe);

    const dash_cmd = b.addRunArtifact(dash_exe);
    dash_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| dash_cmd.addArgs(args);

    const dashboard_step = b.step("dashboard", "Run the ITI Test Dashboard TUI");
    dashboard_step.dependOn(&dash_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("tui", tui_dep.module("tui"));
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run ITI unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
