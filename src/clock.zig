const std = @import("std");
const module = @import("module.zig");
const c = @cImport(@cInclude("time.h")); // strftime, time, localtime_r

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    var now_raw: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now_raw, &tm);

    var buf: [20]u8 = undefined; // exactly 16 bytes + NUL
    const written = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M", &tm);
    if (written == 0) return "n/a"[0..];
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ self.icons, buf[0..written] }) catch "n/a"[0..];
}

pub const Clock = module.Module{
    .name = "Clock",
    .icons = "^fg(7788AA)  󱑆 ^fg()",
    .fetch = fetch,
};
