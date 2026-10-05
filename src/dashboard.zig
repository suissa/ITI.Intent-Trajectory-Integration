//! ITI Test Dashboard — real TUI built on top of tui.zig.
//!
//! Layout (as specified in issue #5):
//!   - Fixed header: black background, "Intent Trajectory Integration" centered,
//!     with the word "Trajectory" highlighted in light blue.
//!   - Body grid: "<" and ">" side buttons (previous/next test, only while PAUSED),
//!     a central "Executar" button that disappears while a test is running, and a
//!     live signale-styled log stream of the real Trajectory event stream.
//!   - Fixed footer: execution progress bar with percentage.
//!   - Theme: dracula.
//!
//! Entry points:
//!   - `zig build dashboard` runs this file's `main()` directly.
//!   - `zig build run -Dui=tui ...` routes through `main.zig`, which calls
//!     `dashboardMain()` here so the tests execute INSIDE the dashboard.

const std = @import("std");
const tui = @import("tui");

const dsl = @import("dsl.zig");
const profile_mod = @import("profile.zig");
const trajectory = @import("trajectory.zig");

/// Path to the spec file embedded by `dashboardMain` when no `-Dspec` was given.
const default_spec = "examples/login.iti";

pub const SystemState = enum {
    idle,
    running,
    paused,
    stopped,
    finished,

    pub fn label(self: SystemState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .running => "RUNNING",
            .paused => "PAUSED",
            .stopped => "STOPPED",
            .finished => "FINISHED",
        };
    }

    /// signale-style badge tag for this state.
    pub fn badgeTag(self: SystemState) []const u8 {
        return switch (self) {
            .idle => "READY",
            .running => "RUN",
            .paused => "HOLD",
            .stopped => "END",
            .finished => "DONE",
        };
    }

    pub fn badgeColor(self: SystemState) tui.Color {
        return switch (self) {
            .idle => tui.Color.hex(0x6272A4),
            .running => tui.Color.hex(0x8BE9FD),
            .paused => tui.Color.hex(0xF1FA8C),
            .stopped => tui.Color.hex(0xFF5555),
            .finished => tui.Color.hex(0x50FA7B),
        };
    }
};

/// One comptime-embedded `.iti` specification plus its selected profile.
pub const SuiteEntry = struct {
    name: []const u8,
    spec_name: []const u8,
    profile_name: []const u8,
    steps: []const dsl.Step,
    probes: []const ProbeDesc,
};

/// Builds the full dashboard suite at comptime from an embedded spec + profile.
/// `steps` and `probes` must be comptime-known slices (their addresses are
/// embedded directly into the returned slice, which lives in static memory).
pub fn buildSuite(
    comptime steps: []const dsl.Step,
    comptime probes: []const ProbeDesc,
    comptime spec_name: []const u8,
    comptime profile_name: []const u8,
) []const SuiteEntry {
    const entries: []const SuiteEntry = &.{.{
        .name = spec_name ++ " · " ++ profile_name,
        .spec_name = spec_name,
        .profile_name = profile_name,
        .steps = steps,
        .probes = probes,
    }};
    return entries;
}

pub const ProbeDesc = struct { kind: trajectory.EventKind, name: []const u8 };

fn profile_probe_count(comptime profile: profile_mod.TestSet) usize {
    var count: usize = 0;
    inline for (@typeInfo(profile_mod.TestSet).@"struct".fields) |field| {
        if (@field(profile, field.name)) count += 1;
    }
    return count;
}

pub fn profileProbes(comptime profile: profile_mod.TestSet) [profile_probe_count(profile)]ProbeDesc {
    var out: [profile_probe_count(profile)]ProbeDesc = undefined;
    var index: usize = 0;
    inline for (@typeInfo(profile_mod.TestSet).@"struct".fields) |field| {
        if (@field(profile, field.name)) {
            const name = field.name;
            const kind: trajectory.EventKind = if (std.mem.startsWith(u8, name, "data_"))
                .data_probe
            else if (std.mem.eql(u8, name, "benchmark") or
                std.mem.eql(u8, name, "load") or
                std.mem.eql(u8, name, "stress"))
                .benchmark_sample
            else
                .expansion;
            out[index] = .{ .kind = kind, .name = name };
            index += 1;
        }
    }
    return out;
}

/// Clips a UTF-8 string to at most `cells` terminal columns starting at byte
/// offset `start`, honoring double-width codepoints. Pure function so it can be
/// unit tested without a terminal.
pub fn clipSegment(comptime src: []const u8, start: usize, cells: usize, max_w: usize) struct { text: []const u8, cells: usize } {
    _ = max_w;
    var taken: usize = 0;
    var i: usize = @min(start, src.len);
    const begin = i;
    while (i < src.len) : (i += std.unicode.utf8ByteSequenceLength(src[i]) catch 1) {
        const cp = std.unicode.utf8Decode(src[i .. i + (std.unicode.utf8ByteSequenceLength(src[i]) catch 1)]) catch break;
        const cw: usize = if (cp >= 0x1100 and
            (cp <= 0x115F or cp == 0x2329 or cp == 0x232A or
                (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
                (cp >= 0xAC00 and cp <= 0xD7A3) or
                (cp >= 0xF900 and cp <= 0xFAFF) or
                (cp >= 0xFE10 and cp <= 0xFE19) or
                (cp >= 0xFE30 and cp <= 0xFE6F) or
                (cp >= 0xFF01 and cp <= 0xFF60) or
                (cp >= 0xFFE0 and cp <= 0xFFE6)))
            2
        else
            1;
        if (taken + cw > cells) break;
        taken += cw;
    }
    return .{ .text = src[begin..i], .cells = taken };
}

// ============================================
// Log model (signale identity)
// ============================================

pub const LogLine = struct {
    time: [8]u8 = [_]u8{' '} ** 8,
    level_tag: [8]u8 = undefined,
    tag_len: u8 = 0,
    scope: [12]u8 = undefined,
    scope_len: u8 = 0,
    message: [log_line_len]u8 = undefined,
    message_len: u16 = 0,
    color: tui.Color = tui.Color.hex(0xF8F8F2),
    bold: bool = false,

    pub fn tag(self: *const LogLine) []const u8 {
        return self.level_tag[0..self.tag_len];
    }

    pub fn scopeText(self: *const LogLine) []const u8 {
        return self.scope[0..self.scope_len];
    }

    pub fn text(self: *const LogLine) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Renders one signale-flavored log line into `buf`, returning the slice written.
/// Kept as a pure function so it can be unit tested without a terminal.
pub fn formatLogLine(line: LogLine, buf: []u8) ![]u8 {
    var tag_buf: [8]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "{s} [{s:>5.5}] {s:<9.9} │ {s}",
        .{ line.time[0..], upperInto(line.tag(), &tag_buf), line.scopeText(), line.text() },
    );
}

const max_log_lines = 512;
const log_line_len = 220;

// ============================================
// Dashboard root widget
// ============================================

pub const Dashboard = struct {
    suite: []const SuiteEntry,
    state: SystemState = .idle,
    current_test: usize = 0,

    emitted_events: usize = 0,
    total_events: usize = 0,
    elapsed_ms: u64 = 0,
    last_tick_ns: i128 = 0,

    log_meta: [max_log_lines]LogLine = [_]LogLine{.{}} ** max_log_lines,
    log_count: usize = 0,
    log_scroll: usize = 0,
    terminal_width: u16 = 0,
    terminal_height: u16 = 0,

    hover_prev: bool = false,
    hover_next: bool = false,
    hover_exec: bool = false,
    hover_pause: bool = false,
    hover_stop: bool = false,

    pub fn init(suite: []const SuiteEntry) Dashboard {
        var self = Dashboard{ .suite = suite };
        self.totalEvents();
        self.pushSystem(.idle, "dashboard pronto · {d} teste(s) no fluxo · pressione ENTER ou clique em Executar", .{self.suite.len});
        return self;
    }

    fn totalEvents(self: *Dashboard) void {
        var total: usize = 0;
        for (self.suite) |entry| total += entry.steps.len + entry.probes.len + 4;
        self.total_events = total;
    }

    fn selected(self: *Dashboard) SuiteEntry {
        return self.suite[self.current_test];
    }

    // ----- actions -----------------------------------------------------------

    fn execute(self: *Dashboard) void {
        if (self.state == .running) return;
        if (self.state == .paused) {
            self.state = .running;
            self.last_tick_ns = std.time.nanoTimestamp();
            self.pushSystem(.running, "execução retomada", .{});
            return;
        }
        if (self.state == .stopped or self.state == .finished) {
            self.emitted_events = 0;
            self.elapsed_ms = 0;
        }
        self.state = .running;
        self.last_tick_ns = std.time.nanoTimestamp();
        const entry = self.selected();
        self.pushSystem(.running, "executando '{s}' · perfil {s}", .{ entry.spec_name, entry.profile_name });
    }

    fn pause(self: *Dashboard) void {
        if (self.state != .running) return;
        self.state = .paused;
        self.pushSystem(.paused, "estado do sistema: PAUSED · use ◂ ▸ para navegar entre testes", .{});
    }

    fn stop(self: *Dashboard) void {
        if (self.state != .running and self.state != .paused) return;
        self.state = .stopped;
        self.pushSystem(.stopped, "estado do sistema: STOPPED · execução interrompida em {d}/{d} eventos", .{ self.emitted_events, self.total_events });
    }

    fn previous(self: *Dashboard) void {
        if (self.state != .paused) return;
        if (self.current_test == 0) {
            self.pushSystem(.paused, "não há teste anterior", .{});
            return;
        }
        self.current_test -= 1;
        self.pushSystem(.paused, "navegando para teste anterior · agora em {s}", .{self.selected().name});
    }

    fn next(self: *Dashboard) void {
        if (self.state != .paused) return;
        if (self.current_test + 1 >= self.suite.len) {
            self.pushSystem(.paused, "não há próximo teste", .{});
            return;
        }
        self.current_test += 1;
        self.pushSystem(.paused, "navegando para próximo teste · agora em {s}", .{self.selected().name});
    }

    // ----- runner integration --------------------------------------------------

    /// Emits the next pending trajectory event of the selected test through the
    /// shared Console projection AND mirrors it into the dashboard log stream.
    fn emitNextEvent(self: *Dashboard, out: *trajectory.Console) bool {
        const entry = self.selected();
        const steps = entry.steps;
        const probes = entry.probes;
        const trajectory_name = "iti.intent-trajectory";

        const track_started_count = steps.len;
        const expansion_assert_count = steps.len;
        const track_finished_count = steps.len;
        const probes_count = probes.len;
        const per_test = track_started_count + expansion_assert_count + track_finished_count + probes_count + 4;

        var test_index: usize = 0;
        var base: usize = 0;
        while (test_index < self.suite.len) : (test_index += 1) {
            if (base + per_test > self.emitted_events) break;
            base += per_test;
        }
        if (base + per_test <= self.emitted_events) return false;

        const i = self.emitted_events - base;
        const step_index = if (i < 3 * steps.len) (i / 3) else null;
        const phase = if (i < 3 * steps.len) (i % 3) else 0;

        if (i == 0) {
            self.log(.info, "RUN", "run_started", entry.name, tui.Color.hex(0xBD93F9));
            out.emit(.{ .kind = .run_started, .trajectory = trajectory_name, .name = entry.profile_name });
        } else if (i == 1) {
            self.log(.info, "TRJ", "trajectory_started", trajectory_name, tui.Color.hex(0x8BE9FD));
            out.emit(.{ .kind = .trajectory_started, .trajectory = trajectory_name });
        } else if (step_index) |si| {
            const step = steps[si];
            const track = stepTrack(step.kind);
            switch (phase) {
                0 => {
                    self.log(.debug, "TRK", "track_started", step.raw, tui.Color.hex(0x8BE9FD));
                    out.emit(.{ .kind = .track_started, .trajectory = trajectory_name, .track = track, .name = step.raw });
                },
                1 => {
                    if (step.kind == .hope or step.kind == .hope_see) {
                        self.log(.success, "OK", "assertion_passed", step.object, tui.Color.hex(0x50FA7B));
                        out.emit(.{
                            .kind = .assertion_passed,
                            .trajectory = trajectory_name,
                            .track = track,
                            .name = step.object,
                            .status = .passed,
                        });
                    } else {
                        self.log(.action, "ACT", "expansion", step.raw, tui.Color.hex(0xF8F8F2));
                        out.emit(.{
                            .kind = .expansion,
                            .trajectory = trajectory_name,
                            .track = track,
                            .name = step.raw,
                            .status = .observed,
                        });
                    }
                },
                else => {
                    self.log(.success, "END", "track_finished", track, tui.Color.hex(0x50FA7B));
                    out.emit(.{
                        .kind = .track_finished,
                        .trajectory = trajectory_name,
                        .track = track,
                        .status = .passed,
                    });
                },
            }
        } else if (i >= 3 * steps.len and i < 3 * steps.len + probes_count) {
            const pi = i - 3 * steps.len;
            const probe = probes[pi];
            const label = switch (probe.kind) {
                .data_probe => "DAT",
                .benchmark_sample => "PRF",
                else => "PRB",
            };
            self.log(.action, label, @tagName(probe.kind), probe.name, tui.Color.hex(0xFFB86C));
            out.emit(.{
                .kind = probe.kind,
                .trajectory = trajectory_name,
                .track = probe.name,
                .name = "selected",
                .status = .observed,
            });
        } else if (i == 3 * steps.len + probes_count) {
            self.log(.info, "TRJ", "trajectory_finished", trajectory_name, tui.Color.hex(0x50FA7B));
            out.emit(.{ .kind = .trajectory_finished, .trajectory = trajectory_name, .status = .passed });
        } else if (i == 3 * steps.len + probes_count + 1) {
            self.log(.success, "RUN", "run_finished", entry.name, tui.Color.hex(0x50FA7B));
            out.emit(.{ .kind = .run_finished, .trajectory = trajectory_name, .status = .passed });
        } else {
            return false;
        }

        self.emitted_events += 1;
        if (self.emitted_events >= self.total_events) {
            self.state = .finished;
            self.pushSystem(.finished, "todos os eventos do fluxo foram observados · 100%", .{});
        }
        return true;
    }

    fn stepTrack(kind: dsl.StepKind) []const u8 {
        return switch (kind) {
            .actor => "actor.bind",
            .open => "browser.open",
            .type_into => "browser.type",
            .click => "browser.click",
            .wish => "intent.wish",
            .hope_see => "assertion.see",
            .hope => "assertion.hope",
            .with => "intent.context",
        };
    }

    // ----- logging -------------------------------------------------------------

    const Level = enum { info, debug, success, action, warn };

    fn pushRaw(self: *Dashboard, line: LogLine) void {
        var slot: usize = undefined;
        if (self.log_count < max_log_lines) {
            slot = self.log_count;
            self.log_count += 1;
        } else {
            // Scroll the log window by shifting everything up one row.
            std.mem.copyForwards(LogLine, &self.log_meta, self.log_meta[1..]);
            slot = max_log_lines - 1;
        }

        self.log_meta[slot] = line;
    }

    /// Appends a signale-styled log entry to the dashboard stream.
    fn log(
        self: *Dashboard,
        level: Level,
        tag: []const u8,
        scope: []const u8,
        message: []const u8,
        color: tui.Color,
    ) void {
        var line = LogLine{};
        timestampInto(&line.time);
        copyBounded(tag, &line.level_tag, &line.tag_len);
        copyBounded(scope, &line.scope, &line.scope_len);
        var msg_buf: [log_line_len]u8 = undefined;
        const msg = sanitize(message, &msg_buf);
        copyBoundedSlice(msg, &line.message, &line.message_len);
        line.color = color;
        line.bold = level == .success or level == .info;
        self.pushRaw(line);
    }

    fn pushSystem(self: *Dashboard, state: SystemState, comptime fmt: []const u8, args: anytype) void {
        var msg_buf: [log_line_len]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch msg_buf[0..0];
        var line = LogLine{};
        timestampInto(&line.time);
        copyBounded(state.badgeTag(), &line.level_tag, &line.tag_len);
        copyBounded("SYS", &line.scope, &line.scope_len);
        copyBoundedSlice(msg, &line.message, &line.message_len);
        line.color = state.badgeColor();
        line.bold = true;
        self.pushRaw(line);
    }

    // ----- events ---------------------------------------------------------------

    pub fn handleEvent(self: *Dashboard, event: tui.Event) tui.EventResult {
        switch (event) {
            .key => |ke| {
                if (ke.modifiers.ctrl) return .ignored;
                switch (ke.key) {
                    .char => |c| switch (std.ascii.toLower(c)) {
                        'e', 'r' => { self.execute(); return .needs_redraw; },
                        'p' => { self.pause(); return .needs_redraw; },
                        's', 'x' => { self.stop(); return .needs_redraw; },
                        '[' => { self.previous(); return .needs_redraw; },
                        ']' => { self.next(); return .needs_redraw; },
                        'k' => { self.scrollLogs(1); return .needs_redraw; },
                        'j' => { self.scrollLogs(-1); return .needs_redraw; },
                        else => {},
                    },
                    .enter, .space => { self.execute(); return .needs_redraw; },
                    .left => { self.previous(); return .needs_redraw; },
                    .right => { self.next(); return .needs_redraw; },
                    .up => { self.scrollLogs(1); return .needs_redraw; },
                    .down => { self.scrollLogs(-1); return .needs_redraw; },
                    else => {},
                }
            },
            .mouse => |me| {
                switch (me.kind) {
                    .press => {
                        if (hitPrev(me.x, me.y)) self.previous();
                        if (hitNext(me.x, me.y)) self.next();
                        if (hitExec(me.x, me.y)) self.execute();
                        if (self.hitPause(me.x, me.y)) {
                            if (self.state == .paused) self.execute() else self.pause();
                        }
                        if (self.hitStop(me.x, me.y)) self.stop();
                        return .needs_redraw;
                    },
                    .release => return .needs_redraw,
                    .move => {
                        const prev_hover = self.hover_prev;
                        const next_hover = self.hover_next;
                        const exec_hover = self.hover_exec;
                        const pause_hover = self.hover_pause;
                        const stop_hover = self.hover_stop;
                        self.hover_prev = hitPrev(me.x, me.y);
                        self.hover_next = hitNext(me.x, me.y);
                        self.hover_exec = hitExec(me.x, me.y);
                        self.hover_pause = self.hitPause(me.x, me.y);
                        self.hover_stop = self.hitStop(me.x, me.y);
                        if (prev_hover != self.hover_prev or next_hover != self.hover_next or
                            exec_hover != self.hover_exec or pause_hover != self.hover_pause or
                            stop_hover != self.hover_stop) return .needs_redraw;
                    },
                    else => {},
                }
            },
            .resize => return .needs_redraw,
            else => {},
        }
        return .ignored;
    }

    fn scrollLogs(self: *Dashboard, delta: isize) void {
        if (delta > 0) {
            self.log_scroll +|= @intCast(delta);
        } else if (self.log_scroll >= @abs(delta)) {
            self.log_scroll -= @intCast(@abs(delta));
        } else self.log_scroll = 0;
    }

    // ----- rendering ------------------------------------------------------------

    pub fn render(self: *Dashboard, ctx: *tui.RenderContext) void {
        self.terminal_width = ctx.bounds.width;
        self.terminal_height = ctx.bounds.height;
        var sub = ctx.getSubScreen();
        const w = sub.width;
        const h = sub.height;
        if (w < 20 or h < 10) return;

        // Background (dracula surface).
        sub.setStyle(.{ .fg = tui.Color.hex(0xF8F8F2), .bg = tui.Color.hex(0x282A36) });
        sub.clear();

        renderHeader(&sub, w);
        renderBody(&sub, self, w, h);
        renderFooter(&sub, self, w, h);
    }

    fn renderHeader(sub: *tui.SubScreen, w: u16) void {
        sub.setStyle(.{ .fg = tui.Color.white, .bg = tui.Color.black, .attrs = .{ .bold = true } });
        sub.fill(' ');

        const text_width: usize = "Intent ".len + "Trajectory".len + " Integration".len;
        var x: usize = 0;
        if (w > text_width) x = (@as(usize, w) - text_width) / 2;

        sub.moveCursor(@intCast(x), 0);
        sub.putString("Intent ");
        sub.setStyle(.{ .fg = tui.Color.light_blue, .bg = tui.Color.black, .attrs = .{ .bold = true } });
        sub.putString("Trajectory");
        sub.setStyle(.{ .fg = tui.Color.white, .bg = tui.Color.black, .attrs = .{ .bold = true } });
        sub.putString(" Integration");

        sub.setStyle(.{ .fg = tui.Color.hex(0x6272A4), .bg = tui.Color.hex(0x282A36) });
        sub.moveCursor(0, 1);
        sub.hline(0, 1, w, '─');
    }

    fn renderBody(sub: *tui.SubScreen, self: *Dashboard, w: u16, h: u16) void {
        const body_top: u16 = 2;
        const body_bottom: u16 = h - 3; // footer occupies controls + progress rows

        // Row 1: test navigation grid.
        const nav_y = body_top;
        const left_x: u16 = 2;
        const right_x: u16 = w - 6;
        const center_w: u16 = 16;
        const center_x: u16 = (w - center_w) / 2;

        const paused = self.state == .paused;

        drawButton(sub, left_x, nav_y, 4, "<", paused and self.current_test > 0, self.hover_prev, false);
        drawButton(sub, right_x, nav_y, 4, ">", paused and self.current_test + 1 < self.suite.len, self.hover_next, false);

        // Executar stays in the body. While active, Pause/Stop move to
        // the fixed footer below (renderFooter).
        if (self.state != .running and self.state != .paused) {
            drawButton(sub, center_x, nav_y, center_w, " Executar ", true, self.hover_exec, true);
        }

        // Row 2: current test + system state badges.
        const entry = self.selected();
        var info_buf: [log_line_len]u8 = undefined;
        const pct = self.progressPercentage();
        const info = std.fmt.bufPrint(
            &info_buf,
            "▣ teste {d}/{d}: {s}   estado: {s}   progresso: {d}%",
            .{ self.current_test + 1, self.suite.len, entry.name, self.state.label(), pct },
        ) catch "ITI dashboard";
        sub.setStyle(.{ .fg = tui.Color.hex(0x6272A4) });
        sub.moveCursor(2, nav_y + 2);
        sub.putString(info);

        // Logs panel border.
        const panel_top = nav_y + 3;
        const panel_bottom = body_bottom;
        if (panel_bottom > panel_top) {
            sub.setStyle(.{ .fg = tui.Color.hex(0x6272A4) });
            sub.hline(1, panel_top, w - 2, '─');
            sub.hline(1, panel_bottom, w - 2, '─');
            sub.vline(1, panel_top + 1, panel_bottom - panel_top - 1, '│');
            sub.vline(w - 2, panel_top + 1, panel_bottom - panel_top - 1, '│');

            const title = " ── LOGS · signale ─────────────────────────── ";
            sub.setStyle(.{ .fg = tui.Color.hex(0xBD93F9), .attrs = .{ .bold = true } });
            sub.moveCursor(2, panel_top);
            sub.putString(title);

            // Log lines.
            const visible_rows = panel_bottom - panel_top - 1;
            var available: usize = self.log_count -| self.log_scroll;
            if (available > visible_rows) available = visible_rows;
            const start_idx = self.log_count - self.log_scroll - available;

            var row: usize = 0;
            while (row < available) : (row += 1) {
                const idx = start_idx + row;
                if (idx >= self.log_count) break;
                const y = panel_top + 1 + @as(u16, @intCast(row));
                if (y >= panel_bottom) break;
                drawLogLine(sub, &self.log_meta[idx], 2, y, w - 4);
            }
        }
    }

    fn drawLogLine(sub: *tui.SubScreen, meta: *const LogLine, x: u16, y: u16, max_w: u16) void {
        const dim = tui.Style{ .fg = tui.Color.hex(0x6272A4) };
        const badge = tui.Style{ .fg = tui.Color.hex(0x282A36), .bg = meta.color, .attrs = .{ .bold = true } };
        const scope_style = tui.Style{
            .fg = meta.color,
            .attrs = if (meta.bold) .{ .bold = true } else .{},
        };
        const msg_style = tui.Style{ .fg = tui.Color.hex(0xF8F8F2) };

        var row_buf: [log_line_len + 32]u8 = undefined;
        var tag_buf: [8]u8 = undefined;
        const full = std.fmt.bufPrint(
            &row_buf,
            "{s} [{s:>5.5}] {s:<9.9} │ {s}",
            .{ meta.time[0..], upperInto(meta.tag(), &tag_buf), meta.scopeText(), meta.text() },
        ) catch "ITI log";

        // Column widths in cells: time(8) + " [" (2) + tag(5) + "] " (2) + scope(9) + " | " -> badge/scope offsets.
        const time_cells: usize = 8;
        const tag_cells: usize = 5;
        const scope_cells: usize = 9;

        const prefix_len = time_cells + 2 + tag_cells + 2 + scope_cells + 3; // up to message start

        var remaining: usize = max_w;
        var col: u16 = x;

        // Segment 1: timestamp (dim).
        {
            const seg = clipSegment(full, 0, time_cells, remaining);
            sub.setStyle(dim);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 2: " [" literal.
        {
            const seg = clipSegment(full, time_cells, 2, remaining);
            sub.setStyle(dim);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 3: uppercase badge on colored background.
        {
            const seg = clipSegment(full, time_cells + 2, tag_cells, remaining);
            sub.setStyle(badge);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 4: "] " literal.
        {
            const seg = clipSegment(full, time_cells + 2 + tag_cells, 2, remaining);
            sub.setStyle(dim);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 5: scope.
        {
            const seg = clipSegment(full, time_cells + 2 + tag_cells + 2, scope_cells, remaining);
            sub.setStyle(scope_style);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 6: " │ " separator.
        {
            const seg = clipSegment(full, prefix_len - 3, 3, remaining);
            sub.setStyle(dim);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
            col += @intCast(seg.cells);
            remaining -= @min(remaining, seg.cells);
        }
        // Segment 7: message (white).
        {
            const seg = clipSegment(full, prefix_len, remaining, remaining);
            sub.setStyle(msg_style);
            sub.moveCursor(col, y);
            sub.putString(seg.text);
        }
    }

    fn renderFooter(sub: *tui.SubScreen, self: *Dashboard, w: u16, h: u16) void {
        const controls_y = h - 2;
        const bar_y = h - 1;

        sub.setStyle(.{ .fg = tui.Color.hex(0x6272A4), .bg = tui.Color.hex(0x282A36) });
        sub.moveCursor(0, controls_y);
        sub.hline(0, controls_y, w, '─');

        // When execution is active, the footer owns the two lifecycle controls.
        if (self.state == .running or self.state == .paused) {
            const pause_label: []const u8 = if (self.state == .paused) "Resume" else "Pause";
            const pause_w: u16 = if (self.state == .paused) 8 else 7;
            const stop_w: u16 = 6;
            const gap: u16 = 2;
            const total_w = pause_w + gap + stop_w;
            const start_x = (w -| total_w) / 2;
            drawButton(sub, start_x, controls_y, pause_w, pause_label, true, self.hover_pause or self.hover_exec, true);
            drawButton(sub, start_x + pause_w + gap, controls_y, stop_w, "Stop", true, self.hover_stop, false);
        }

        sub.setStyle(.{ .fg = tui.Color.hex(0x282A36), .bg = tui.Color.hex(0x44475A) });
        sub.moveCursor(0, bar_y);
        sub.hline(0, bar_y, w, ' ');

        const pct = self.progressPercentage();
        var label_buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buf,
            " ITI · {s} · {d}% ",
            .{ self.state.label(), pct },
        ) catch " ITI ";

        sub.setStyle(.{ .fg = tui.Color.hex(0xF8F8F2), .bg = tui.Color.hex(0x44475A), .attrs = .{ .bold = true } });
        sub.moveCursor(0, bar_y);
        sub.putString(label);

        const label_w: u16 = @intCast(@min(label.len, w));
        const bar_w = w -| label_w -| 1;
        if (bar_w > 2) {
            const filled: u16 = @intFromFloat(@floor(@as(f32, @floatFromInt(bar_w)) * @as(f32, @floatFromInt(pct)) / 100.0));
            sub.setStyle(.{ .fg = tui.Color.hex(0x50FA7B), .bg = tui.Color.hex(0x282A36) });
            sub.moveCursor(label_w, bar_y);
            var i: u16 = 0;
            while (i < filled) : (i += 1) sub.putChar('█');
            sub.setStyle(.{ .fg = tui.Color.hex(0x44475A), .bg = tui.Color.hex(0x282A36) });
            while (i < bar_w) : (i += 1) sub.putChar('░');
        }
    }

    // ----- layout hit-testing -----------------------------------------------------

    fn hitPrev(x: u16, y: u16) bool {
        return rectHit(x, y, 2, 2, 4, 1);
    }

    fn hitNext(x: u16, y: u16) bool {
        return rectHit(x, y, 2, 2, 4, 1);
    }

    fn hitExec(x: u16, y: u16) bool {
        return rectHit(x, y, 2, 2, 16, 1);
    }

    fn hitPause(self: *Dashboard, x: u16, y: u16) bool {
        if (self.state != .running and self.state != .paused) return false;
        const pause_w: u16 = if (self.state == .paused) 8 else 7;
        const total_w = pause_w + 2 + 6;
        const start_x = (self.terminal_width -| total_w) / 2;
        return rectHit(x, y, start_x, self.terminal_height -| 2, pause_w, 1);
    }

    fn hitStop(self: *Dashboard, x: u16, y: u16) bool {
        if (self.state != .running and self.state != .paused) return false;
        const pause_w: u16 = if (self.state == .paused) 8 else 7;
        const gap: u16 = 2;
        const start_x = (self.terminal_width -| (pause_w + gap + 6)) / 2;
        return rectHit(x, y, start_x + pause_w + gap, self.terminal_height -| 2, 6, 1);
    }

};

fn rectHit(px: u16, py: u16, x: u16, y: u16, w: u16, h: u16) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

fn drawButton(sub: *tui.SubScreen, x: u16, y: u16, w: u16, label: []const u8, enabled: bool, hovered: bool, primary: bool) void {
    _ = w;
    const bg_color: tui.Color = if (!enabled)
        tui.Color.hex(0x44475A)
    else if (hovered)
        (if (primary) tui.Color.hex(0xFF79C6) else tui.Color.hex(0xBD93F9))
    else if (primary)
        tui.Color.hex(0x6272A4)
    else
        tui.Color.hex(0x44475A);

    const fg_color: tui.Color = if (!enabled)
        tui.Color.hex(0x6272A4)
    else if (hovered)
        tui.Color.hex(0x282A36)
    else
        tui.Color.hex(0xF8F8F2);

    sub.setStyle(.{ .fg = fg_color, .bg = bg_color, .attrs = .{ .bold = true } });
    sub.moveCursor(x, y);
    sub.putString("[" ++ label ++ "]");
}

fn upperInto(src: []const u8, buf: []u8) []u8 {
    var i: usize = 0;
    while (i < src.len and i < buf.len) : (i += 1) {
        buf[i] = std.ascii.toUpper(src[i]);
    }
    return buf[0..i];
}

/// Comptime-safe uppercase for short fixed tags (badges). For runtime strings
/// the dashboard uses `upperInto` with a caller-provided buffer.
fn upper(comptime src: []const u8) []const u8 {
    comptime {
        var buf: [src.len]u8 = undefined;
        for (src, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return &buf;
    }
}

/// Copies `src` into a fixed-size array field, tracking its length.
fn copyBounded(src: []const u8, comptime buf: anytype, len: anytype) void {
    comptime {
        if (@TypeOf(buf).kind() != .pointer) @compileError("copyBounded expects a pointer to an array");
    }
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = @intCast(n);
}

fn copyBoundedSlice(src: []const u8, buf: []u8, len: *u16) void {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    len.* = @intCast(n);
}

/// Strips control characters so a malformed message cannot break the TUI grid.
fn sanitize(src: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (src) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isControl(c)) ' ' else c;
        n += 1;
    }
    return buf[0..n];
}

fn padRight(src: []const u8, buf: []u8) []u8 {
    var i: usize = 0;
    while (i < src.len and i < buf.len) : (i += 1) buf[i] = src[i];
    while (i < buf.len and i < 8) : (i += 1) buf[i] = ' ';
    return buf[0..i];
}

fn timestampInto(buf: *[8]u8) []const u8 {
    const ts = std.time.timestamp();
    const tm = std.time.gmtime(&ts);
    const hh = tm.hour;
    const mm = tm.min;
    const ss = tm.sec;
    buf[0] = '0' + @as(u8, @intCast(hh / 10));
    buf[1] = '0' + @as(u8, @intCast(hh % 10));
    buf[2] = ':';
    buf[3] = '0' + @as(u8, @intCast(mm / 10));
    buf[4] = '0' + @as(u8, @intCast(mm % 10));
    buf[5] = ':';
    buf[6] = '0' + @as(u8, @intCast(ss / 10));
    buf[7] = '0' + @as(u8, @intCast(ss % 10));
    return buf[0..8];
}

// ============================================
// App driver (custom loop over tui.zig pieces)
// ============================================

pub fn run(suite: []const SuiteEntry, projection: trajectory.Projection) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term = try tui.terminal.Terminal.init(.{});
    defer term.deinit();

    const size = try term.getSize();
    var scr = try tui.screen.Screen.init(allocator, size.cols, size.rows);
    defer scr.deinit();

    var rend = tui.renderer.Renderer.init(allocator);
    defer rend.deinit();

    var reader = tui.input.InputReader.init(allocator);
    _ = &reader;

    var dash = Dashboard.init(suite);
    var console = trajectory.Console{ .projection = projection };

    const theme = tui.theme.Theme.dracula;
    _ = theme;

    const frame_ns: i128 = 25_000_000; // ~40 fps
    var next_frame = std.time.nanoTimestamp();

    while (true) {
        // Poll input without blocking (termios VTIME gives us a ~100ms window).
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buf: [64]u8 = undefined;
        const n = stdin.read(&buf) catch 0;
        if (n > 0) {
            if (try reader.parse(buf[0..n])) |event| {
                // Global quit keys.
                if (event == .key) {
                    const ke = event.key;
                    if (ke.key == .escape or
                        (ke.modifiers.ctrl and ke.key == .char and (ke.key.char == 'c' or ke.key.char == 'q')))
                    {
                        break;
                    }
                }
                if (event == .resize) {
                    try scr.resize(event.resize.cols, event.resize.rows);
                    rend.invalidate();
                }
                _ = dash.handleEvent(event);
            }
        }

        // Advance the real runner while the system is RUNNING.
        if (dash.state == .running) {
            const tick_start = std.time.nanoTimestamp();
            _ = dash.emitNextEvent(&console);
            dash.elapsed_ms += @intCast(@divTrunc(std.time.nanoTimestamp() - tick_start, 1_000_000));
        }

        // Render.
        scr.clear();
        var ctx = tui.widget.RenderContext{
            .screen = &scr,
            .theme = &tui.theme.Theme.dracula,
            .bounds = .{ .x = 0, .y = 0, .width = scr.width, .height = scr.height },
            .clip = .{ .x = 0, .y = 0, .width = scr.width, .height = scr.height },
            .focused_id = null,
            .time_ns = @intCast(std.time.nanoTimestamp()),
        };
        dash.render(&ctx);
        try rend.render(&scr);

        next_frame += frame_ns;
        const now = std.time.nanoTimestamp();
        if (next_frame > now) {
            std.Thread.sleep(@intCast(next_frame - now));
        } else {
            next_frame = now;
        }
    }
}

// ============================================
// Entry point — `zig build dashboard`
// ============================================

pub fn main() !void {
    const build_options = @import("build_options");

    const parsed_spec = blk: {
        @setEvalBranchQuota(100_000);
        break :blk dsl.parse(@embedFile(build_options.spec));
    };
    const selected_profile = blk: {
        @setEvalBranchQuota(10_000);
        break :blk profile_mod.fromName(build_options.profile);
    };
    const suite = buildSuite(parsed_spec, selected_profile, build_options.spec, build_options.profile);

    try run(suite, .tui);
}

// ============================================
// Tests
// ============================================

test "formatLogLine renders signale-style columns" {
    var buf: [220]u8 = undefined;
    const out = try formatLogLine(.{
        .time = "12:34:56",
        .level_tag = "info",
        .scope = "RUN",
        .message = "hello",
    }, &buf);
    try std.testing.expectEqualStrings("12:34:56  info   RUN     │ hello", out);
}

test "system state labels match issue vocabulary" {
    try std.testing.expectEqualStrings("PAUSED", SystemState.paused.label());
    try std.testing.expectEqualStrings("STOPPED", SystemState.stopped.label());
    try std.testing.expectEqualStrings("RUNNING", SystemState.running.label());
}
