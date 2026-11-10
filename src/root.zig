pub const dsl = @import("dsl.zig");
pub const profile = @import("profile.zig");
pub const trajectory = @import("trajectory.zig");
pub const runner = @import("runner.zig");
pub const dashboard = @import("dashboard.zig");
pub const websocket = @import("websocket.zig");
pub const cdp_websocket = @import("cdp_websocket.zig");
pub const cdp = @import("cdp.zig");
pub const browser = @import("browser.zig");
pub const opentrajectory = @import("opentrajectory.zig");
pub const data_plane = @import("data_plane.zig");

test {
    _ = dsl;
    _ = profile;
    _ = trajectory;
    _ = runner;
    _ = dashboard;
    _ = websocket;
    _ = cdp_websocket;
    _ = cdp;
    _ = browser;
    _ = opentrajectory;
    _ = data_plane;
}
