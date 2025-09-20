const std = @import("std");
const module = @import("module.zig");

const sysfs_power_dir = "/sys/class/power_supply";
const acpi_battery_dir = "/proc/acpi/battery";

const DetectionState = struct {
    known: bool,
    has_battery: bool = false,
};

var detection_state = DetectionState{ .known = false };

const low_battery_threshold_pct = 15.0;
const degrade_threshold_ratio = 0.8;
const max_eta_hours = 24.0;

const BatteryState = enum {
    charging,
    discharging,
    full,
    unknown,
};

const MeasurementUnit = enum {
    none,
    energy_uwh,
    charge_uah,
};

const Aggregate = struct {
    measurement: MeasurementUnit = .none,
    rate_unit: MeasurementUnit = .none,
    device_count: usize = 0,

    total_now: u128 = 0,
    total_full: u128 = 0,
    total_full_design: u128 = 0,
    have_full_design: bool = false,

    rate_out: u128 = 0,
    rate_in: u128 = 0,

    capacity_sum: f64 = 0.0,
    capacity_weight: usize = 0,

    low_battery_flag: bool = false,
    degrade_flag: bool = false,

    charging_present: bool = false,
    discharging_present: bool = false,
    full_present: bool = false,
    unknown_present: bool = false,

    fn addMeasurement(self: *Aggregate, unit: MeasurementUnit, now_raw: u128, full: u128, full_design: ?u128) void {
        if (full == 0) return;

        const now = if (now_raw > full) full else now_raw;

        if (self.measurement == .none)
            self.measurement = unit
        else if (self.measurement != unit)
            return;

        self.total_now += now;
        self.total_full += full;
        if (full_design) |design| {
            self.total_full_design += design;
            self.have_full_design = true;
        }
    }

    fn addRate(self: *Aggregate, unit: MeasurementUnit, status: BatteryState, rate: u128) void {
        if (rate == 0) return;

        if (self.rate_unit == .none)
            self.rate_unit = unit
        else if (self.rate_unit != unit)
            return;

        switch (status) {
            .charging => self.rate_in += rate,
            .discharging => self.rate_out += rate,
            else => {},
        }
    }
};

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    var agg_opt = collectSysfs();
    if (agg_opt == null) {
        agg_opt = collectAcpi();
    }

    if (agg_opt == null) {
        if (!detection_state.known) {
            detection_state = DetectionState{ .known = true, .has_battery = false };
        }
        return "n/a";
    }

    var agg = agg_opt.?;
    if (agg.device_count == 0) return "n/a";

    if (!detection_state.known or !detection_state.has_battery) {
        detection_state = DetectionState{ .known = true, .has_battery = true };
    }

    const percent = computePercent(&agg) orelse return "n/a";
    const state = deriveState(agg);
    const glyph = stateGlyph(state);

    const eta_hours = computeEtaHours(agg, state);

    if (percent < low_battery_threshold_pct)
        agg.low_battery_flag = true;

    const clamped_percent = std.math.clamp(percent, 0.0, 100.0);
    const rounded_percent = std.math.floor(clamped_percent + 0.5);
    const percent_int = @as(u8, @intFromFloat(rounded_percent));

    var eta_buf: [8]u8 = undefined;
    const eta_segment = formatEta(eta_hours, &eta_buf);

    const warn_low = if (agg.low_battery_flag) " !" else "";
    const warn_degrade = if (agg.degrade_flag) " d" else "";

    return std.fmt.allocPrint(
        allocator,
        "{s} {d:>3}%{s}{s}{s}{s}",
        .{ self.icons, percent_int, glyph, eta_segment, warn_low, warn_degrade },
    ) catch "n/a";
}

fn collectSysfs() ?Aggregate {
    var dir = std.fs.openDirAbsolute(sysfs_power_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var agg = Aggregate{};

    var it = dir.iterate();
    while (true) {
        const next = it.next() catch return null;
        if (next == null) break;
        const entry = next.?;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sysfs_power_dir, entry.name }) catch continue;

        if (!isBattery(entry_path)) continue;

        processSysfsBattery(entry_path, &agg);
    }

    if (agg.device_count == 0) return null;
    return agg;
}

fn collectAcpi() ?Aggregate {
    var dir = std.fs.openDirAbsolute(acpi_battery_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var agg = Aggregate{};

    var it = dir.iterate();
    while (true) {
        const next = it.next() catch return null;
        if (next == null) break;
        const entry = next.?;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ acpi_battery_dir, entry.name }) catch continue;

        processAcpiBattery(entry_path, &agg);
    }

    if (agg.device_count == 0) return null;
    return agg;
}

fn isBattery(dir_path: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (readTrimmed(dir_path, "type", &buf)) |slice| {
        if (eqlAsciiIgnoreCase(slice, "Battery")) return true;
    }
    if (readTrimmed(dir_path, "TYPE", &buf)) |slice| {
        if (eqlAsciiIgnoreCase(slice, "Battery")) return true;
    }
    return false;
}

fn processSysfsBattery(dir_path: []const u8, agg: *Aggregate) void {
    agg.device_count += 1;

    const status = readStatus(dir_path);
    switch (status) {
        .charging => agg.charging_present = true,
        .discharging => agg.discharging_present = true,
        .full => agg.full_present = true,
        .unknown => agg.unknown_present = true,
    }

    const capacity_value = readUnsigned(dir_path, "capacity");
    var percent_from_ratio: ?f64 = null;

    var measurement_unit: MeasurementUnit = .none;
    var now_value: u128 = 0;
    var full_value: u128 = 0;
    var design_value: ?u128 = null;

    if (readUnsigned(dir_path, "energy_now")) |energy_now| {
        if (readUnsigned(dir_path, "energy_full")) |energy_full| {
            measurement_unit = .energy_uwh;
            now_value = @as(u128, energy_now);
            full_value = @as(u128, energy_full);
            if (readUnsigned(dir_path, "energy_full_design")) |design|
                design_value = @as(u128, design);
        }
    }

    if (measurement_unit == .none) {
        if (readUnsigned(dir_path, "charge_now")) |charge_now| {
            if (readUnsigned(dir_path, "charge_full")) |charge_full| {
                measurement_unit = .charge_uah;
                now_value = @as(u128, charge_now);
                full_value = @as(u128, charge_full);
                if (readUnsigned(dir_path, "charge_full_design")) |design|
                    design_value = @as(u128, design);
            }
        }
    }

    if (measurement_unit != .none and full_value != 0) {
        agg.addMeasurement(measurement_unit, now_value, full_value, design_value);
        const ratio = (@as(f64, @floatFromInt(now_value)) / @as(f64, @floatFromInt(full_value))) * 100.0;
        const ratio_clamped = std.math.clamp(ratio, 0.0, 100.0);
        percent_from_ratio = ratio_clamped;
        if (design_value) |design| {
            if (design != 0) {
                const design_ratio = @as(f64, @floatFromInt(full_value)) / @as(f64, @floatFromInt(design));
                if (design_ratio < degrade_threshold_ratio)
                    agg.degrade_flag = true;
            }
        }
    }

    if (capacity_value) |cap| {
        agg.capacity_sum += @as(f64, @floatFromInt(cap));
        agg.capacity_weight += 1;
        if (@as(f64, @floatFromInt(cap)) < low_battery_threshold_pct)
            agg.low_battery_flag = true;
    } else if (percent_from_ratio) |pct| {
        agg.capacity_sum += pct;
        agg.capacity_weight += 1;
        if (pct < low_battery_threshold_pct)
            agg.low_battery_flag = true;
    }

    const voltage_now = readUnsigned(dir_path, "voltage_now");
    const voltage_design = readUnsigned(dir_path, "voltage_min_design");
    const voltage_for_power = voltage_now orelse voltage_design;

    const power_now = readSigned(dir_path, "power_now");
    const current_now = readSigned(dir_path, "current_now");

    if (measurement_unit == .energy_uwh) {
        if (powerMagnitude(power_now, current_now, voltage_for_power)) |power| {
            agg.addRate(.energy_uwh, status, power);
        }
    } else if (measurement_unit == .charge_uah) {
        if (currentMagnitude(current_now)) |curr| {
            agg.addRate(.charge_uah, status, curr);
        } else if (powerMagnitude(power_now, current_now, voltage_for_power)) |power| {
            agg.addRate(.energy_uwh, status, power);
        }
    } else {
        if (powerMagnitude(power_now, current_now, voltage_for_power)) |power| {
            agg.addRate(.energy_uwh, status, power);
        }
    }
}

fn processAcpiBattery(dir_path: []const u8, agg: *Aggregate) void {
    var info_buf: [512]u8 = undefined;
    const info = readWholeFile(dir_path, "info", &info_buf) orelse return;
    var state_buf: [512]u8 = undefined;
    const state = readWholeFile(dir_path, "state", &state_buf) orelse return;

    const present = lineEquals(info, "present:", "yes") and lineEquals(state, "present:", "yes");
    if (!present) return;

    const last_full_mwh = parseAcpiMilliValue(info, "last full capacity:") orelse parseAcpiMilliValue(info, "last full capacity (mWh):") orelse return;
    const design_mwh = parseAcpiMilliValue(info, "design capacity:") orelse parseAcpiMilliValue(info, "design capacity (mWh):");
    const remaining_mwh = parseAcpiMilliValue(state, "remaining capacity:") orelse parseAcpiMilliValue(state, "remaining capacity (mWh):") orelse return;
    const rate_mw = parseAcpiMilliValue(state, "present rate:") orelse parseAcpiMilliValue(state, "present rate (mW):");

    const charging_state = parseAcpiState(state);
    agg.device_count += 1;

    switch (charging_state) {
        .charging => agg.charging_present = true,
        .discharging => agg.discharging_present = true,
        .full => agg.full_present = true,
        .unknown => agg.unknown_present = true,
    }

    const now_uwh = @as(u128, @intCast(remaining_mwh)) * 1000;
    const full_uwh = @as(u128, @intCast(last_full_mwh)) * 1000;
    const design_uwh: ?u128 = if (design_mwh) |val| @as(u128, @intCast(val)) * 1000 else null;

    if (full_uwh != 0) {
        agg.addMeasurement(.energy_uwh, now_uwh, full_uwh, design_uwh);
        const ratio = (@as(f64, @floatFromInt(now_uwh)) / @as(f64, @floatFromInt(full_uwh))) * 100.0;
        agg.capacity_sum += ratio;
        agg.capacity_weight += 1;
        if (ratio < low_battery_threshold_pct)
            agg.low_battery_flag = true;
        if (design_uwh) |design| {
            if (design != 0) {
                const design_ratio = @as(f64, @floatFromInt(full_uwh)) / @as(f64, @floatFromInt(design));
                if (design_ratio < degrade_threshold_ratio)
                    agg.degrade_flag = true;
            }
        }
    }

    if (rate_mw) |mw| {
        const rate_uw = @as(u128, @intCast(mw)) * 1000;
        agg.addRate(.energy_uwh, charging_state, rate_uw);
    }
}

fn computePercent(agg: *Aggregate) ?f64 {
    if (agg.measurement != .none and agg.total_full != 0) {
        const now_f = @as(f64, @floatFromInt(agg.total_now));
        const full_f = @as(f64, @floatFromInt(agg.total_full));
        return (now_f / full_f) * 100.0;
    }
    if (agg.capacity_weight != 0) {
        return agg.capacity_sum / @as(f64, @floatFromInt(agg.capacity_weight));
    }
    return null;
}

fn deriveState(agg: Aggregate) BatteryState {
    if (agg.discharging_present and !agg.charging_present)
        return .discharging;
    if (agg.charging_present and !agg.discharging_present)
        return .charging;
    if (!agg.charging_present and !agg.discharging_present and agg.full_present)
        return .full;
    if (agg.device_count == 0)
        return .unknown;
    return .unknown;
}

fn stateGlyph(state: BatteryState) []const u8 {
    return switch (state) {
        .charging => "^fg(f9e2af) 󱐋 ^fg()",
        .discharging => "",
        .full => "^fg(85AF5F) ✓ ^fg()",
        .unknown => "^fg(FFAA88) ! ^fg()",
    };
}

fn computeEtaHours(agg: Aggregate, state: BatteryState) ?f64 {
    if (agg.measurement == .none or agg.rate_unit == .none) return null;
    if (agg.measurement != agg.rate_unit) return null;

    if (state == .discharging) {
        if (agg.rate_out == 0 or agg.total_now == 0) return null;
        const remaining = @as(f64, @floatFromInt(agg.total_now));
        const rate = @as(f64, @floatFromInt(agg.rate_out));
        return remaining / rate;
    }

    if (state == .charging) {
        if (agg.rate_in == 0 or agg.total_full <= agg.total_now) return null;
        const delta = @as(f64, @floatFromInt(agg.total_full - agg.total_now));
        const rate = @as(f64, @floatFromInt(agg.rate_in));
        return delta / rate;
    }

    return null;
}

fn formatEta(eta_hours: ?f64, buf: *[8]u8) []const u8 {
    if (eta_hours) |eta| {
        if (!std.math.isFinite(eta)) return "";
        const clamped = @min(eta, max_eta_hours);
        if (clamped <= 0.0) return "";
        const total_minutes_f = clamped * 60.0;
        const total_minutes = @as(u64, @intFromFloat(std.math.floor(total_minutes_f + 0.5)));
        if (total_minutes == 0) return "";
        const hours = total_minutes / 60;
        const minutes = total_minutes % 60;
        return std.fmt.bufPrint(buf, " {d:02}:{d:02}", .{ hours, minutes }) catch "";
    }
    return "";
}

fn readTrimmed(dir: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, file }) catch return null;
    const f = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer f.close();

    const amt = f.read(buf) catch return null;
    if (amt == 0) return null;
    return std.mem.trim(u8, buf[0..amt], " \t\r\n");
}

fn readUnsigned(dir: []const u8, file: []const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const slice = readTrimmed(dir, file, &buf) orelse return null;
    return std.fmt.parseInt(u64, slice, 10) catch null;
}

fn readSigned(dir: []const u8, file: []const u8) ?i64 {
    var buf: [64]u8 = undefined;
    const slice = readTrimmed(dir, file, &buf) orelse return null;
    return std.fmt.parseInt(i64, slice, 10) catch null;
}

fn readStatus(dir: []const u8) BatteryState {
    var buf: [64]u8 = undefined;
    const slice = readTrimmed(dir, "status", &buf) orelse return .unknown;
    if (eqlAsciiIgnoreCase(slice, "charging"))
        return .charging;
    if (eqlAsciiIgnoreCase(slice, "discharging"))
        return .discharging;
    if (eqlAsciiIgnoreCase(slice, "full"))
        return .full;
    return .unknown;
}

fn powerMagnitude(power_now: ?i64, current_now: ?i64, voltage: ?u64) ?u128 {
    if (power_now) |p| {
        const mag = if (p < 0) -p else p;
        if (mag > 0)
            return @as(u128, @intCast(mag));
    }
    if (current_now) |curr| {
        const mag_curr = if (curr < 0) -curr else curr;
        if (mag_curr > 0) {
            if (voltage) |vol| {
                const product = @as(u128, @intCast(mag_curr)) * @as(u128, vol);
                const scaled = product / 1_000_000;
                if (scaled > 0)
                    return scaled;
            }
        }
    }
    return null;
}

fn currentMagnitude(current_now: ?i64) ?u128 {
    if (current_now) |curr| {
        const mag = if (curr < 0) -curr else curr;
        if (mag > 0)
            return @as(u128, @intCast(mag));
    }
    return null;
}

fn readWholeFile(dir: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, file }) catch return null;
    const f = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer f.close();
    const amt = f.readAll(buf) catch return null;
    if (amt == 0) return null;
    return buf[0..amt];
}

fn parseAcpiMilliValue(contents: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) {
            const rest = line[key.len..];
            var tok = std.mem.tokenizeScalar(u8, rest, ' ');
            while (tok.next()) |t| {
                if (t.len == 0) continue;
                return std.fmt.parseInt(u64, t, 10) catch null;
            }
        }
    }
    return null;
}

fn parseAcpiState(contents: []const u8) BatteryState {
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "charging state:")) {
            const rest = line["charging state:".len..];
            var tok = std.mem.tokenizeScalar(u8, rest, ' ');
            if (tok.next()) |state_token| {
                if (eqlAsciiIgnoreCase(state_token, "charging")) return .charging;
                if (eqlAsciiIgnoreCase(state_token, "discharging")) return .discharging;
                if (eqlAsciiIgnoreCase(state_token, "charged")) return .full;
                return .unknown;
            }
        }
    }
    return .unknown;
}

fn lineEquals(contents: []const u8, key: []const u8, value: []const u8) bool {
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) {
            const rest = std.mem.trim(u8, line[key.len..], " \t");
            return eqlAsciiIgnoreCase(rest, value);
        }
    }
    return false;
}

fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ch, idx| {
        if (toLowerAscii(ch) != toLowerAscii(b[idx])) return false;
    }
    return true;
}

fn toLowerAscii(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

pub const Battery = module.Module{
    .name = "Battery",
    .icons = "^fg(57C7FF)  ^fg()",
    .fetch = fetch,
};

pub fn isSupported() bool {
    if (detection_state.known) return detection_state.has_battery;
    detection_state = DetectionState{
        .known = true,
        .has_battery = detectBatteryPresence(),
    };
    return detection_state.has_battery;
}

fn detectBatteryPresence() bool {
    if (detectSysfsPresence()) return true;
    if (detectAcpiPresence()) return true;
    return false;
}

fn detectSysfsPresence() bool {
    var dir = std.fs.openDirAbsolute(sysfs_power_dir, .{ .iterate = true }) catch return false;
    defer dir.close();

    var it = dir.iterate();
    while (true) {
        const next = it.next() catch return false;
        if (next == null) break;
        const entry = next.?;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sysfs_power_dir, entry.name }) catch continue;
        if (isBattery(entry_path)) return true;
    }
    return false;
}

fn detectAcpiPresence() bool {
    var dir = std.fs.openDirAbsolute(acpi_battery_dir, .{ .iterate = true }) catch return false;
    defer dir.close();

    var it = dir.iterate();
    while (true) {
        const next = it.next() catch return false;
        if (next == null) break;
        const entry = next.?;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ acpi_battery_dir, entry.name }) catch continue;
        if (hasAcpiBattery(entry_path)) return true;
    }
    return false;
}

fn hasAcpiBattery(dir_path: []const u8) bool {
    var info_buf: [256]u8 = undefined;
    var state_buf: [256]u8 = undefined;
    const info = readWholeFile(dir_path, "info", &info_buf) orelse return false;
    const state = readWholeFile(dir_path, "state", &state_buf) orelse return false;
    return lineEquals(info, "present:", "yes") and lineEquals(state, "present:", "yes");
}
