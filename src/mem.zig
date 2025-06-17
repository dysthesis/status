const std = @import("std");
const module = @import("module.zig");

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{ .mode = .read_only }) catch return "n/a"[0..];
    defer file.close();

    var buf: [2048]u8 = undefined;
    const len = file.readAll(&buf) catch return "n/a";

    var total_kib: u64 = 0;
    var avail_kib: u64 = 0;

    var it = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (it.next()) |ln| {
        if (std.mem.startsWith(u8, ln, "MemTotal:") or std.mem.startsWith(u8, ln, "MemAvailable:")) {
            // split the *whole* line on spaces, first numeric token is the value
            var tok = std.mem.tokenizeScalar(u8, ln, ' ');
            _ = tok.next(); // first token is the label
            while (tok.next()) |t| { // skip empty runs
                if (t.len != 0) {
                    const val = std.fmt.parseInt(u64, t, 10) catch return "n/a"[0..];
                    if (std.mem.startsWith(u8, ln, "MemTotal:"))
                        total_kib = val
                    else
                        avail_kib = val;
                    break;
                }
            }
        }
    }

    const used_kib = total_kib - avail_kib;
    const used_gib = @as(f64, @floatFromInt(used_kib)) / 1024.0 / 1024.0; // GiB

    return std.fmt.allocPrint(allocator, "{s} {d:.1} GiB", .{ self.icons, used_gib }) catch "n/a"[0..];
}

pub const Mem = module.Module{
    .name = "Memory",
    .icons = "^fg(708090)   ^fg()",
    .fetch = fetch,
};
