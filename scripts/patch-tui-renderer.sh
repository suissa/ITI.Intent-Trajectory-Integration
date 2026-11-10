#!/usr/bin/env sh
set -eu

file="vendor/tui/src/core/renderer.zig"
if [ ! -f "$file" ]; then
  echo "TUI.zig renderer not found at $file" >&2
  exit 1
fi

if grep -q "const OutputWriter = struct" "$file"; then
  exit 0
fi

perl -0pi -e '
s/(const style_mod = .*?;\n)/$1\nconst OutputWriter = struct {\n    output: *std.ArrayListUnmanaged(u8),\n    allocator: std.mem.Allocator,\n\n    pub fn writeAll(self: *OutputWriter, bytes: []const u8) !void {\n        try self.output.appendSlice(self.allocator, bytes);\n    }\n\n    pub fn print(self: *OutputWriter, comptime fmt: []const u8, args: anytype) !void {\n        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);\n        defer self.allocator.free(formatted);\n        try self.writeAll(formatted);\n    }\n};\n/s;
s/const buf_writer = self\.output_buffer\.writer\(self\.allocator\);/var buf_writer = OutputWriter{ .output = \&self.output_buffer, .allocator = self.allocator };/;
s/self\.renderDiff\(current, prev, buf_writer\)/self.renderDiff(current, prev, \&buf_writer)/g;
s/self\.renderFull\(current, buf_writer\)/self.renderFull(current, \&buf_writer)/g;
' "$file"
