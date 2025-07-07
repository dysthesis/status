const std = @import("std");
const module = @import("module.zig");

/// Helper that runs `task export` (or anything passed in `argv`) and returns its stdout as a fresh
/// heap slice.
fn run_command(allocator: std.mem.Allocator) ![]u8 {
    const argv = &[_][]const u8{
        "/usr/bin/env",
        "task",
        "rc.verbose:nothing", // silence headers
        "+READY",
        "status:pending",
        "export",
    };

    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16 * 1024, // enough for ~500 tasks
    });
    defer allocator.free(res.stderr); // we don’t use stderr
    return res.stdout; // caller frees
}

/// Parse a Taskwarrior JSON array (produced by `task ... export`) and pull out description and due
/// date of the first task.
fn first_task(json: []const u8, a: std.mem.Allocator) ?struct { desc: []const u8, due: ?[]const u8 } {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]"))
        return null; // nothing ready

    // scratch allocator (4 KiB stack, spills to caller’s arena)
    var sfa = std.heap.stackFallback(4096, a);
    const gpa = sfa.get();

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array or root.array.items.len == 0)
        return null;

    var best_idx: usize = 0;
    var best_urg: f64 = -1;
    for (root.array.items, 0..) |item, idx| {
        if (item != .object) continue; // safety
        const urg = if (item.object.get("urgency")) |u|
            switch (u) {
                .float => u.float,
                .integer => @as(f64, @floatFromInt(u.integer)),
                else => 0,
            }
        else
            0;
        if (urg > best_urg) {
            best_urg = urg;
            best_idx = idx;
        }
    }

    const best = root.array.items[best_idx];
    if (best != .object) return null; // defensive

    const obj = best.object;
    const desc_v = obj.get("description") orelse return null;
    if (desc_v != .string) return null;
    const desc = desc_v.string;

    // optional due date
    const due_opt_v = obj.get("due");
    var due_opt: ?[]const u8 = null;
    if (due_opt_v) |dv|
        if (dv == .string and dv.string.len >= 8) { // YYYYMMDD...
            var buf: [10]u8 = undefined; // YYYY-MM-DD
            std.mem.copyForwards(u8, buf[0..4], dv.string[0..4]);
            buf[4] = '-';
            std.mem.copyForwards(u8, buf[5..7], dv.string[4..6]);
            buf[7] = '-';
            std.mem.copyForwards(u8, buf[8..10], dv.string[6..8]);
            due_opt = buf[0..];
        };

    return .{ .desc = desc, .due = due_opt };
}

/// The `fetch` function exposed to the status-bar core.
fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const raw = run_command(allocator) catch {
        return "err"[0..]; // spawn/read failure
    };
    defer allocator.free(raw);

    const task_opt = first_task(raw, allocator);
    if (task_opt == null)
        return std.fmt.allocPrint(allocator, "{s} No tasks", .{self.icons}) catch "n/a"[0..];

    const task = task_opt.?;
    return if (task.due) |d|
        std.fmt.allocPrint(allocator, "{s} {s} due {s}", .{ self.icons, task.desc, d }) catch "n/a"[0..]
    else
        std.fmt.allocPrint(allocator, "{s} {s}", .{ self.icons, task.desc }) catch "n/a"[0..];
}

/// Public value the status-bar will import.
pub const Taskwarrior = module.Module{
    .name = "Taskwarrior",
    .icons = "^fg(85AF5F)   ^fg()",
    .fetch = fetch,
};
