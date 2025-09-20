const std = @import("std");
const module = @import("module.zig");

const DynLib = std.DynLib;

const SndMixer = opaque {};
const SndMixerElem = opaque {};

const FnMixerOpen = *const fn ([*c]?*SndMixer, c_int) callconv(.C) c_int;
const FnMixerClose = *const fn (*SndMixer) callconv(.C) c_int;
const FnMixerAttach = *const fn (*SndMixer, [*:0]const u8) callconv(.C) c_int;
const FnSelemRegister = *const fn (*SndMixer, ?*anyopaque, ?*anyopaque) callconv(.C) c_int;
const FnMixerLoad = *const fn (*SndMixer) callconv(.C) c_int;
const FnFirstElem = *const fn (*SndMixer) callconv(.C) ?*SndMixerElem;
const FnElemNext = *const fn (*SndMixerElem) callconv(.C) ?*SndMixerElem;
const FnSelemIsActive = *const fn (*SndMixerElem) callconv(.C) c_int;
const FnSelemHasPlaybackVolume = *const fn (*SndMixerElem) callconv(.C) c_int;
const FnHandleEvents = *const fn (*SndMixer) callconv(.C) c_int;
const FnSelemHasPlaybackChannel = *const fn (*SndMixerElem, c_int) callconv(.C) c_int;
const FnSelemGetPlaybackVolume = *const fn (*SndMixerElem, c_int, *c_long) callconv(.C) c_int;
const FnSelemHasPlaybackSwitch = *const fn (*SndMixerElem) callconv(.C) c_int;
const FnSelemGetPlaybackSwitch = *const fn (*SndMixerElem, c_int, *c_int) callconv(.C) c_int;
const FnSelemGetPlaybackVolumeRange = *const fn (*SndMixerElem, *c_long, *c_long) callconv(.C) c_int;

const ALSA_CHANNEL_MAX: c_int = 31;

const AlsaFns = struct {
    mixer_open: FnMixerOpen,
    mixer_close: FnMixerClose,
    mixer_attach: FnMixerAttach,
    selem_register: FnSelemRegister,
    mixer_load: FnMixerLoad,
    first_elem: FnFirstElem,
    elem_next: FnElemNext,
    selem_is_active: FnSelemIsActive,
    selem_has_playback_volume: FnSelemHasPlaybackVolume,
    handle_events: FnHandleEvents,
    selem_has_playback_channel: FnSelemHasPlaybackChannel,
    selem_get_playback_volume: FnSelemGetPlaybackVolume,
    selem_has_playback_switch: FnSelemHasPlaybackSwitch,
    selem_get_playback_switch: FnSelemGetPlaybackSwitch,
    selem_get_playback_volume_range: FnSelemGetPlaybackVolumeRange,
};

const VolumeInfo = struct {
    percent: u16,
    muted: bool,
    clipped: bool,
};

const Backend = enum { uninitialized, alsa, pactl, unavailable };
const PactlState = enum { unknown, available, missing };

const ACTIVE_ICON = "^fg(66CCFF)  󰕾 ^fg()";
const MUTED_ICON = "^fg(66CCFF)  󰖁 ^fg()";

var backend_state: Backend = .uninitialized;
var pactl_state: PactlState = .unknown;
var backend_mutex = std.Thread.Mutex{};

var alsa_lib: ?DynLib = null;
var alsa_fns: ?AlsaFns = null;
var alsa_load_failed = false;

fn failAlsaLoad(lib: *DynLib) bool {
    lib.close();
    alsa_load_failed = true;
    return false;
}

fn ensureAlsaFns() bool {
    if (alsa_fns != null) return true;
    if (alsa_load_failed) return false;

    var lib = DynLib.openZ("libasound.so.2") catch DynLib.openZ("libasound.so") catch {
        alsa_load_failed = true;
        return false;
    };

    var fns: AlsaFns = undefined;

    fns.mixer_open = lib.lookup(FnMixerOpen, "snd_mixer_open") orelse return failAlsaLoad(&lib);
    fns.mixer_close = lib.lookup(FnMixerClose, "snd_mixer_close") orelse return failAlsaLoad(&lib);
    fns.mixer_attach = lib.lookup(FnMixerAttach, "snd_mixer_attach") orelse return failAlsaLoad(&lib);
    fns.selem_register = lib.lookup(FnSelemRegister, "snd_mixer_selem_register") orelse return failAlsaLoad(&lib);
    fns.mixer_load = lib.lookup(FnMixerLoad, "snd_mixer_load") orelse return failAlsaLoad(&lib);
    fns.first_elem = lib.lookup(FnFirstElem, "snd_mixer_first_elem") orelse return failAlsaLoad(&lib);
    fns.elem_next = lib.lookup(FnElemNext, "snd_mixer_elem_next") orelse return failAlsaLoad(&lib);
    fns.selem_is_active = lib.lookup(FnSelemIsActive, "snd_mixer_selem_is_active") orelse return failAlsaLoad(&lib);
    fns.selem_has_playback_volume = lib.lookup(FnSelemHasPlaybackVolume, "snd_mixer_selem_has_playback_volume") orelse return failAlsaLoad(&lib);
    fns.handle_events = lib.lookup(FnHandleEvents, "snd_mixer_handle_events") orelse return failAlsaLoad(&lib);
    fns.selem_has_playback_channel = lib.lookup(FnSelemHasPlaybackChannel, "snd_mixer_selem_has_playback_channel") orelse return failAlsaLoad(&lib);
    fns.selem_get_playback_volume = lib.lookup(FnSelemGetPlaybackVolume, "snd_mixer_selem_get_playback_volume") orelse return failAlsaLoad(&lib);
    fns.selem_has_playback_switch = lib.lookup(FnSelemHasPlaybackSwitch, "snd_mixer_selem_has_playback_switch") orelse return failAlsaLoad(&lib);
    fns.selem_get_playback_switch = lib.lookup(FnSelemGetPlaybackSwitch, "snd_mixer_selem_get_playback_switch") orelse return failAlsaLoad(&lib);
    fns.selem_get_playback_volume_range = lib.lookup(FnSelemGetPlaybackVolumeRange, "snd_mixer_selem_get_playback_volume_range") orelse return failAlsaLoad(&lib);

    alsa_lib = lib;
    alsa_fns = fns;
    return true;
}

const AlsaState = struct {
    handle: ?*SndMixer = null,
    elem: ?*SndMixerElem = null,
    vol_min: c_long = 0,
    vol_max: c_long = 0,
};

var alsa_state = AlsaState{};

fn teardownAlsa() void {
    if (alsa_state.handle) |handle| {
        if (alsa_fns) |fns| {
            _ = fns.mixer_close(handle);
        }
    }
    alsa_state = AlsaState{};
}

fn setupAlsa() bool {
    if (alsa_state.handle != null and alsa_state.elem != null and alsa_state.vol_max > alsa_state.vol_min) {
        return true;
    }

    if (!ensureAlsaFns()) return false;
    const fns = alsa_fns orelse return false;

    teardownAlsa();

    var handle_ptr: ?*SndMixer = null;
    if (fns.mixer_open(&handle_ptr, 0) < 0) return false;

    const card_candidates = [_][*c]const u8{
        "default\x00",
        "pulse\x00",
        "pipewire\x00",
    };

    var attached = false;
    for (card_candidates) |card| {
        if (fns.mixer_attach(handle_ptr.?, card) >= 0) {
            attached = true;
            break;
        }
    }

    if (!attached) {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    }

    if (fns.selem_register(handle_ptr.?, null, null) < 0) {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    }
    if (fns.mixer_load(handle_ptr.?) < 0) {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    }

    var elem_opt = fns.first_elem(handle_ptr.?);
    while (elem_opt) |current| {
        if (fns.selem_is_active(current) == 0) {
            elem_opt = fns.elem_next(current);
            continue;
        }
        if (fns.selem_has_playback_volume(current) == 0) {
            elem_opt = fns.elem_next(current);
            continue;
        }
        break;
    }

    const elem = elem_opt orelse {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    };

    var min_val: c_long = 0;
    var max_val: c_long = 0;
    if (fns.selem_get_playback_volume_range(elem, &min_val, &max_val) < 0) {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    }

    if (max_val <= min_val) {
        _ = fns.mixer_close(handle_ptr.?);
        return false;
    }

    alsa_state.handle = handle_ptr.?;
    alsa_state.elem = elem;
    alsa_state.vol_min = min_val;
    alsa_state.vol_max = max_val;
    return true;
}

fn queryAlsa(info: *VolumeInfo) bool {
    if (!setupAlsa()) return false;

    const handle = alsa_state.handle orelse return false;
    const elem = alsa_state.elem orelse return false;
    const fns = alsa_fns orelse return false;

    if (fns.handle_events(handle) < 0) {
        teardownAlsa();
        return false;
    }

    const channel_last = ALSA_CHANNEL_MAX;

    var loudest: c_long = alsa_state.vol_min;
    var have_channel = false;
    var any_unmuted = false;
    var seen_switch = false;

    var channel_idx: c_int = 0;
    while (channel_idx <= channel_last) : (channel_idx += 1) {
        const channel: c_int = channel_idx;
        if (fns.selem_has_playback_channel(elem, channel) == 0) continue;
        have_channel = true;

        var vol: c_long = 0;
        if (fns.selem_get_playback_volume(elem, channel, &vol) < 0) continue;

        var switch_val: c_int = 1;
        if (fns.selem_has_playback_switch(elem) != 0) {
            seen_switch = true;
            if (fns.selem_get_playback_switch(elem, channel, &switch_val) < 0) {
                switch_val = 1;
            }
        }

        if (switch_val == 0) {
            continue;
        }

        any_unmuted = true;
        if (vol > loudest) {
            loudest = vol;
        }
    }

    if (!have_channel) {
        teardownAlsa();
        return false;
    }

    const range = alsa_state.vol_max - alsa_state.vol_min;
    if (range <= 0) {
        teardownAlsa();
        return false;
    }

    const base_value = if (any_unmuted) loudest else alsa_state.vol_min;

    var scaled: i128 = (@as(i128, base_value) - @as(i128, alsa_state.vol_min)) * 100;
    scaled += @divTrunc(@as(i128, range), 2);
    if (scaled < 0) scaled = 0;
    var percent = @divTrunc(scaled, @as(i128, range));
    if (percent < 0) percent = 0;
    if (percent > 150) percent = 150;

    info.* = VolumeInfo{
        .percent = @intCast(percent),
        .muted = seen_switch and !any_unmuted,
        .clipped = percent > 100,
    };

    return true;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16_384,
    });
}

fn parseHighestPercent(data: []const u8) ?u16 {
    var idx: usize = 0;
    var found = false;
    var max_percent: u16 = 0;

    while (idx < data.len) {
        const rel = std.mem.indexOfScalar(u8, data[idx..], '%') orelse break;
        const pos = idx + rel;
        var start = pos;
        while (start > idx and std.ascii.isDigit(data[start - 1])) {
            start -= 1;
        }
        if (start == pos) {
            idx = pos + 1;
            continue;
        }
        const digits = std.mem.trim(u8, data[start..pos], " \t");
        if (digits.len == 0) {
            idx = pos + 1;
            continue;
        }
        const value = std.fmt.parseUnsigned(u16, digits, 10) catch {
            idx = pos + 1;
            continue;
        };
        if (!found or value > max_percent) {
            max_percent = value;
            found = true;
        }
        idx = pos + 1;
    }

    if (!found) return null;
    return max_percent;
}

fn parseMute(data: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r\n");
    if (value.len == 0) return null;
    if (std.mem.startsWith(u8, value, "yes")) return true;
    if (std.mem.startsWith(u8, value, "no")) return false;
    return null;
}

fn queryPactl(info: *VolumeInfo, allocator: std.mem.Allocator) bool {
    const volume_result = runCommand(allocator, &[_][]const u8{
        "pactl",
        "get-sink-volume",
        "@DEFAULT_SINK@",
    }) catch |err| {
        if (err == error.FileNotFound) {
            pactl_state = .missing;
        }
        return false;
    };
    defer {
        allocator.free(volume_result.stdout);
        allocator.free(volume_result.stderr);
    }

    switch (volume_result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    const highest = parseHighestPercent(volume_result.stdout) orelse return false;

    const mute_result = runCommand(allocator, &[_][]const u8{
        "pactl",
        "get-sink-mute",
        "@DEFAULT_SINK@",
    }) catch |err| {
        if (err == error.FileNotFound) {
            pactl_state = .missing;
        }
        return false;
    };
    defer {
        allocator.free(mute_result.stdout);
        allocator.free(mute_result.stderr);
    }

    switch (mute_result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    const muted = parseMute(mute_result.stdout) orelse false;

    pactl_state = .available;

    var percent_value = highest;
    if (percent_value > 150) percent_value = 150;

    info.* = VolumeInfo{
        .percent = percent_value,
        .muted = muted,
        .clipped = percent_value > 100,
    };

    return true;
}

fn ensureInfo(info: *VolumeInfo, allocator: std.mem.Allocator) bool {
    var order: [2]Backend = undefined;
    var count: usize = 0;

    switch (backend_state) {
        .uninitialized, .unavailable => {
            order[0] = .alsa;
            count = 1;
            if (pactl_state != .missing) {
                order[count] = .pactl;
                count += 1;
            }
        },
        .alsa => {
            order[0] = .alsa;
            count = 1;
            if (pactl_state != .missing) {
                order[count] = .pactl;
                count += 1;
            }
        },
        .pactl => {
            if (pactl_state != .missing) {
                order[0] = .pactl;
                count = 1;
            }
            order[count] = .alsa;
            count += 1;
        },
    }

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const backend = order[index];
        const ok = switch (backend) {
            .alsa => queryAlsa(info),
            .pactl => queryPactl(info, allocator),
            else => false,
        };

        if (ok) {
            backend_state = backend;
            return true;
        }

        if (backend == .alsa) {
            teardownAlsa();
        }
    }

    backend_state = .uninitialized;
    return false;
}

fn renderOutput(self: module.Module, allocator: std.mem.Allocator, info: VolumeInfo) []const u8 {
    const icon = if (info.muted or info.percent == 0) MUTED_ICON else self.icons;
    const suffix = if (info.muted) " (muted)" else if (info.clipped) " (clip)" else "";

    return std.fmt.allocPrint(allocator, "{s} {d}%{s}", .{ icon, info.percent, suffix }) catch "n/a";
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    var info: VolumeInfo = undefined;

    backend_mutex.lock();
    const ready = ensureInfo(&info, allocator);
    backend_mutex.unlock();

    if (!ready) {
        return "n/a";
    }

    return renderOutput(self, allocator, info);
}

pub const Volume = module.Module{
    .name = "Volume",
    .icons = ACTIVE_ICON,
    .fetch = fetch,
};
