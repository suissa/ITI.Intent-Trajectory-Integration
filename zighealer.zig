const std = @import("std");

const HealingAction = enum {
    init_tui_submodule,
    patch_ci_checkout,
};

const Signature = struct {
    needle: []const u8,
    action: HealingAction,
};

const signatures = [_]Signature{
    .{ .needle = "unable to find module 'tui'", .action = .init_tui_submodule },
    .{ .needle = "unable to find module \"tui\"", .action = .init_tui_submodule },
};

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

fn diagnose(error_text: []const u8) ?HealingAction {
    for (signatures) |s| if (has(error_text, s.needle)) return s.action;
    return null;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
}

fn succeeded(result: std.process.Child.RunResult) bool {
    return result.term.Exited == 0;
}

fn ensureGitmodules(allocator: std.mem.Allocator) !void {
    const declaration =
        "[submodule \"vendor/tui\"]\n" ++
        "\tpath = vendor/tui\n" ++
        "\turl = https://github.com/muhammad-fiaz/tui.zig.git\n";

    const current = readFile(allocator, ".gitmodules") catch |err| switch (err) {
        error.FileNotFound => {
            try writeFile(".gitmodules", declaration);
            std.debug.print("[zighealer] repair: created .gitmodules for vendor/tui\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(current);

    if (has(current, "path = vendor/tui") and has(current, "muhammad-fiaz/tui.zig")) return;

    var merged = std.ArrayList(u8).init(allocator);
    defer merged.deinit();
    try merged.appendSlice(current);
    if (merged.items.len > 0 and merged.items[merged.items.len - 1] != '\n') try merged.append('\n');
    try merged.appendSlice(declaration);
    try writeFile(".gitmodules", merged.items);
    std.debug.print("[zighealer] repair: added vendor/tui to .gitmodules\n", .{});
}

fn ensureWorkflow(allocator: std.mem.Allocator) !void {
    const path = ".github/workflows/test.yml";
    const current = readFile(allocator, path) catch return;
    defer allocator.free(current);

    if (has(current, "submodules: recursive")) {
        std.debug.print("[zighealer] repair: CI already checks out submodules\n", .{});
        return;
    }

    const marker = "uses: actions/checkout@v4";
    const pos = std.mem.indexOf(u8, current, marker) orelse {
        std.debug.print("[zighealer] repair: checkout step not found; no CI edit\n", .{});
        return;
    };
    const end = std.mem.indexOfScalarPos(u8, current, pos, '\n') orelse current.len;

    var patched = std.ArrayList(u8).init(allocator);
    defer patched.deinit();
    try patched.appendSlice(current[0..end]);
    try patched.appendSlice("\n        with:\n          submodules: recursive");
    try patched.appendSlice(current[end..]);
    try writeFile(path, patched.items);
    std.debug.print("[zighealer] repair: enabled recursive submodule checkout\n", .{});
}

fn initTui(allocator: std.mem.Allocator) !void {
    const result = try run(allocator, &.{
        "git", "submodule", "update", "--init", "--recursive", "vendor/tui",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!succeeded(result)) {
        std.debug.print("[zighealer] repair: submodule init failed; retrying CI-safe diagnostics\n", .{});
        if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
        return;
    }
    std.debug.print("[zighealer] repair: vendor/tui initialized\n", .{});
}

fn retryTests(allocator: std.mem.Allocator) !bool {
    const result = try run(allocator, &.{"zig", "build", "test"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (succeeded(result)) {
        std.debug.print("[zighealer] retry: zig build test PASSED\n", .{});
        return true;
    }

    std.debug.print("[zighealer] retry: zig build test FAILED\n", .{});
    if (result.stdout.len > 0) std.debug.print("{s}\n", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
    return false;
}

pub fn heal(allocator: std.mem.Allocator, error_text: []const u8) !bool {
    const action = diagnose(error_text) orelse {
        std.debug.print("[zighealer] diagnose: unknown error; refusing unsafe edits\n", .{});
        return false;
    };

    std.debug.print("[zighealer] diagnose: known rule = {s}\n", .{@tagName(action)});

    switch (action) {
        .init_tui_submodule => {
            try ensureGitmodules(allocator);
            try ensureWorkflow(allocator);
            try initTui(allocator);
        },
        .patch_ci_checkout => {},
    }

    return retryTests(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();
    const error_text = args.next() orelse {
        std.debug.print("usage: ./zighealer \"<build error>\"\n", .{});
        return error.InvalidArguments;
    };

    if (try heal(gpa.allocator(), error_text)) return;
    return error.HealingFailed;
}

test "diagnoses missing tui module" {
    try std.testing.expect(diagnose("panic: unable to find module 'tui'") != null);
}

test "ignores unknown compiler errors" {
    try std.testing.expect(diagnose("error: syntax error") == null);
}
