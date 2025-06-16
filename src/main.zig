const std = @import("std");
const c = @cImport({
    @cInclude("sys/sysinfo.h"); // struct sysinfo + syscall
    @cInclude("stdlib.h"); // getloadavg()
});

fn colour(
    text: []const u8,
    comptime fg: ?[]const u8,
    comptime bg: ?[]const u8,
) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // ── single defer that runs on every exit path ────────────────
    defer {
        if (fg) |_|
            stdout.print("^fg()", .{}) catch
                std.debug.print("failed to print closing fg!\n", .{});
        if (bg) |_|
            stdout.print("^bg()", .{}) catch
                std.debug.print("failed to print closing bg!\n", .{});

        bw.flush() catch {}; // guarantee bytes reach the TTY
    }

    // foreground
    if (fg) |fg_code| {
        errdefer std.debug.print("failed to print opening fg!\n", .{});
        try stdout.print("^fg({s})", .{fg_code});
    }

    // background
    if (bg) |bg_code| {
        errdefer std.debug.print("failed to print opening bg!\n", .{});
        try stdout.print("^bg({s})", .{bg_code});
    }

    try stdout.print("{s}", .{text});
}

pub fn main() !void {
    while (true) {
        var info: c.struct_sysinfo = undefined;
        if (c.sysinfo(&info) != 0) return error.SysInfoFailed;
        const mem_total = info.totalram * info.mem_unit;
        const mem_free = info.freeram * info.mem_unit;
        const mem_used = mem_total - mem_free;
        try colour(mem_used, null, "#ffffff");
    }
}
