const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    while (true) {
        const s = try colour(alloc, "test", null, "#ffffff");
        defer alloc.free(s);

        try stdout.print("{s}", .{s});
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}
/// Print out the given text with the given foreground and background
pub fn colour(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime fg: ?[]const u8,
    comptime bg: ?[]const u8,
) ![]u8 {
    const use_fg = comptime fg != null;
    const use_bg = comptime bg != null;

    const fmt = comptime if (use_fg and use_bg)
        "^fg({s})^bg({s}){s}^fg()^bg()"
    else if (use_fg)
        "^fg({s}){s}^fg()"
    else if (use_bg)
        "^bg({s}){s}^bg()"
    else
        "{s}";

    const args = if (use_fg and use_bg)
        .{ fg.?, bg.?, text }
    else if (use_fg)
        .{ fg.?, text }
    else if (use_bg)
        .{ bg.?, text }
    else
        .{text};

    return std.fmt.allocPrint(allocator, fmt, args);
}
