const std = @import("std");
const capy = @import("capy");

pub fn main() !void {
    try capy.init();
    defer capy.deinit();

    var window = try capy.Window.init();
    const content = try capy.column(.{ .spacing = 14 }, .{
        try capy.row(.{ .spacing = 12 }, .{
            capy.label(.{ .text = "Speed Download", .layout = .{ .font = .{ .size = 24 } } }),
            try capy.expanded(capy.label(.{ .text = "Downloads" })),
            capy.button(.{ .label = "＋ Add URL" }),
        }),
        capy.label(.{ .text = "Paste a link to start a download" }),
        capy.textField(.{ .text = "https://example.com/file.zip" }),
        try capy.row(.{ .spacing = 8 }, .{
            capy.button(.{ .label = "Download" }),
            capy.button(.{ .label = "Pause" }),
            try capy.expanded(capy.label(.{ .text = "Ready" })),
        }),
        try capy.expanded(try capy.column(.{ .spacing = 8 }, .{
            try downloadRow("Ubuntu 24.04 Desktop", "2.4 GB", "Completed", "100%"),
            try downloadRow("SpeedDownload-1.0.0.zip", "84 MB", "Downloading", "68%"),
            try downloadRow("Archive backup.tar", "1.2 GB", "Queued", "Waiting"),
        })),
        capy.label(.{ .text = "HTTP(S) transfers · Resume support · No telemetry" }),
    });

    try window.set(content);
    window.setTitle("Speed Download");
    window.setPreferredSize(960, 640);
    window.show();
    capy.runEventLoop();
}

fn downloadRow(name: []const u8, size: []const u8, status: []const u8, progress: []const u8) !*capy.Container {
    return try capy.column(.{ .spacing = 5 }, .{
        try capy.row(.{ .spacing = 12 }, .{
            try capy.expanded(capy.label(.{ .text = name })),
            capy.label(.{ .text = size }),
            capy.label(.{ .text = status }),
            capy.label(.{ .text = progress }),
        }),
        capy.label(.{ .text = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" }),
    });
}
