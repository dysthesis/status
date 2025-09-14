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
/// date of the first task. Returns freshly allocated slices owned by `a`.
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
    const desc_src = desc_v.string;

    // optional due date
    const due_opt_v = obj.get("due");
    var due_opt: ?[]const u8 = null;
    if (due_opt_v) |dv|
        if (dv == .string and dv.string.len >= 8) { // YYYYMMDD...
            var tmp: [10]u8 = undefined; // YYYY-MM-DD
            std.mem.copyForwards(u8, tmp[0..4], dv.string[0..4]);
            tmp[4] = '-';
            std.mem.copyForwards(u8, tmp[5..7], dv.string[4..6]);
            tmp[7] = '-';
            std.mem.copyForwards(u8, tmp[8..10], dv.string[6..8]);
            const due_buf = a.alloc(u8, 10) catch return null;
            std.mem.copyForwards(u8, due_buf, tmp[0..]);
            due_opt = due_buf;
        };

    // Copy description to caller-owned memory
    const desc_buf = a.alloc(u8, desc_src.len) catch return null;
    std.mem.copyForwards(u8, desc_buf, desc_src);

    return .{ .desc = desc_buf, .due = due_opt };
}

/// The `fetch` function exposed to the status-bar core.
fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const raw = run_command(allocator) catch {
        return "n/a"[0..]; // spawn/read failure
    };
    defer allocator.free(raw);

    const task_opt = first_task(raw, allocator);
    if (task_opt == null)
        return std.fmt.allocPrint(allocator, "{s} No tasks", .{self.icons}) catch "n/a"[0..];

    // Truncate output so this module never emits more than 50 bytes.
    const task = task_opt.?;
    const LIMIT: usize = 100;

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    // Reserve up to LIMIT to reduce reallocs; ignore error, we can still append.
    _ = list.ensureTotalCapacityPrecise(LIMIT) catch {};

    const append_limited = struct {
        fn run(l: *std.ArrayList(u8), seg: []const u8, limit: usize) !void {
            if (l.items.len >= limit) return; // already full
            const rem = limit - l.items.len;
            const take = if (seg.len > rem) rem else seg.len;
            try l.appendSlice(seg[0..take]);
        }
    }.run;

    // icons
    append_limited(&list, self.icons, LIMIT) catch return "n/a";
    // space
    append_limited(&list, " ", LIMIT) catch return "n/a";
    // description (truncated as needed)
    append_limited(&list, task.desc, LIMIT) catch return "n/a";

    if (task.due) |d| {
        append_limited(&list, " due ", LIMIT) catch return "n/a";
        append_limited(&list, d, LIMIT) catch return "n/a";
    }

    return list.toOwnedSlice() catch "n/a";
}

/// Public value the status-bar will import.
pub const Taskwarrior = module.Module{
    .name = "Taskwarrior",
    .icons = "^fg(85AF5F)   ^fg()",
    .fetch = fetch,
};
