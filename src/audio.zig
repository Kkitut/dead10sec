const std = @import("std");
const c = @import("c");

pub const AL_GAIN = 0x100A;
pub const AL_BUFFER = 0x1009;
pub const AL_LOOPING = 0x1007;
pub const AL_SOURCE_STATE = 0x1010;
pub const AL_PLAYING = 0x1012;
pub const AL_FORMAT_MONO16 = 0x1101;
pub const AL_FORMAT_STEREO16 = 0x1103;

pub const OpenAL = struct {
    alcOpenDevice: *const fn (?[*:0]const u8) callconv(.c) ?*anyopaque,
    alcCreateContext: *const fn (?*anyopaque, ?[*]const c_int) callconv(.c) ?*anyopaque,
    alcMakeContextCurrent: *const fn (?*anyopaque) callconv(.c) c_char,
    alcDestroyContext: *const fn (?*anyopaque) callconv(.c) void,
    alcCloseDevice: *const fn (?*anyopaque) callconv(.c) c_char,

    alListenerf: *const fn (c_int, f32) callconv(.c) void,
    alGenBuffers: *const fn (c_int, [*]c_uint) callconv(.c) void,
    alDeleteBuffers: *const fn (c_int, [*]const c_uint) callconv(.c) void,
    alBufferData: *const fn (c_uint, c_int, ?*const anyopaque, c_int, c_int) callconv(.c) void,

    alGenSources: *const fn (c_int, [*]c_uint) callconv(.c) void,
    alDeleteSources: *const fn (c_int, [*]const c_uint) callconv(.c) void,
    alSourcei: *const fn (c_uint, c_int, c_int) callconv(.c) void,
    alSourcef: *const fn (c_uint, c_int, f32) callconv(.c) void,
    alGetSourcei: *const fn (c_uint, c_int, *c_int) callconv(.c) void,
    alSourcePlay: *const fn (c_uint) callconv(.c) void,
    alSourceStop: *const fn (c_uint) callconv(.c) void,
    alSourceRewind: *const fn (c_uint) callconv(.c) void,
};

pub var al: ?OpenAL = null;
const builtin = @import("builtin");

const Library = struct {
    handle: if (builtin.os.tag == .windows) ?*anyopaque else ?std.DynLib,

    pub fn open(name: [:0]const u8) ?Library {
        if (builtin.os.tag == .windows) {
            const h = LoadLibraryA(name.ptr);
            if (h == null) return null;
            return .{ .handle = h };
        } else {
            const dl = std.DynLib.open(name) catch return null;
            return .{ .handle = dl };
        }
    }

    pub fn lookup(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        if (builtin.os.tag == .windows) {
            const proc = GetProcAddress(self.handle.?, name.ptr);
            if (proc == null) return null;
            return @ptrCast(proc);
        } else {
            return self.handle.?.lookup(T, name);
        }
    }

    pub fn close(self: *Library) void {
        if (builtin.os.tag == .windows) {
            if (self.handle) |h| _ = FreeLibrary(h);
            self.handle = null;
        } else {
            if (self.handle) |*dl| dl.close();
            self.handle = null;
        }
    }
};

extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(module: ?*anyopaque) callconv(.winapi) c_int;

pub var al_device: ?*anyopaque = null;
pub var al_context: ?*anyopaque = null;
pub var available: bool = false;
pub var dynlib: ?Library = null;

var sound_arena: std.heap.ArenaAllocator = undefined;
var sound_allocator: std.mem.Allocator = undefined;

pub const MuteMode = enum {
    None,
    Music,
    Master,
};

pub const Sound = struct {
    buffer: c_uint = 0,
    source: c_uint = 0,
    loaded: bool = false,
    volume: f32 = 1.0,

    pub fn play(self: *Sound) void {
        if (!self.loaded or al == null) return;
        al.?.alSourceStop(self.source);
        al.?.alSourceRewind(self.source);
        al.?.alSourcePlay(self.source);
    }

    pub fn stop(self: *Sound) void {
        if (!self.loaded or al == null) return;
        al.?.alSourceStop(self.source);
    }

    pub fn setVolume(self: *Sound, vol: f32) void {
        self.volume = std.math.clamp(vol, 0.0, 10.0);
        if (self.loaded and al != null) {
            al.?.alSourcef(self.source, AL_GAIN, self.volume);
        }
    }

    pub fn setLooping(self: *Sound, loop: bool) void {
        if (self.loaded and al != null) {
            al.?.alSourcei(self.source, AL_LOOPING, if (loop) 1 else 0);
        }
    }

    pub fn isPlaying(self: *Sound) bool {
        if (!self.loaded or al == null) return false;
        var state: c_int = 0;
        al.?.alGetSourcei(self.source, AL_SOURCE_STATE, &state);
        return state == AL_PLAYING;
    }

    pub fn deinit(self: *Sound) void {
        if (self.loaded and al != null) {
            al.?.alDeleteSources(1, @ptrCast(&self.source));
            al.?.alDeleteBuffers(1, @ptrCast(&self.buffer));
            self.loaded = false;
        }
    }
};

pub fn init() void {
    sound_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    sound_allocator = sound_arena.allocator();

    const candidates = [_][:0]const u8{
        "libopenal.so.1",
        "libopenal.so",
        "soft_oal.dll",
        "openal32.dll",
        "OpenAL32.dll",
    };

    for (candidates) |name| {
        if (Library.open(name)) |lib| {
            dynlib = lib;
            break;
        }
    }

    if (dynlib == null) {
        std.debug.print("[Audio] OpenAL library not found, running silent\n", .{});
        available = false;
        return;
    }

    var dl = &dynlib.?;
    const oal = OpenAL{
        .alcOpenDevice = dl.lookup(@TypeOf(al.?.alcOpenDevice), "alcOpenDevice") orelse return silent(),
        .alcCreateContext = dl.lookup(@TypeOf(al.?.alcCreateContext), "alcCreateContext") orelse return silent(),
        .alcMakeContextCurrent = dl.lookup(@TypeOf(al.?.alcMakeContextCurrent), "alcMakeContextCurrent") orelse return silent(),
        .alcDestroyContext = dl.lookup(@TypeOf(al.?.alcDestroyContext), "alcDestroyContext") orelse return silent(),
        .alcCloseDevice = dl.lookup(@TypeOf(al.?.alcCloseDevice), "alcCloseDevice") orelse return silent(),

        .alListenerf = dl.lookup(@TypeOf(al.?.alListenerf), "alListenerf") orelse return silent(),
        .alGenBuffers = dl.lookup(@TypeOf(al.?.alGenBuffers), "alGenBuffers") orelse return silent(),
        .alDeleteBuffers = dl.lookup(@TypeOf(al.?.alDeleteBuffers), "alDeleteBuffers") orelse return silent(),
        .alBufferData = dl.lookup(@TypeOf(al.?.alBufferData), "alBufferData") orelse return silent(),

        .alGenSources = dl.lookup(@TypeOf(al.?.alGenSources), "alGenSources") orelse return silent(),
        .alDeleteSources = dl.lookup(@TypeOf(al.?.alDeleteSources), "alDeleteSources") orelse return silent(),
        .alSourcei = dl.lookup(@TypeOf(al.?.alSourcei), "alSourcei") orelse return silent(),
        .alSourcef = dl.lookup(@TypeOf(al.?.alSourcef), "alSourcef") orelse return silent(),
        .alGetSourcei = dl.lookup(@TypeOf(al.?.alGetSourcei), "alGetSourcei") orelse return silent(),
        .alSourcePlay = dl.lookup(@TypeOf(al.?.alSourcePlay), "alSourcePlay") orelse return silent(),
        .alSourceStop = dl.lookup(@TypeOf(al.?.alSourceStop), "alSourceStop") orelse return silent(),
        .alSourceRewind = dl.lookup(@TypeOf(al.?.alSourceRewind), "alSourceRewind") orelse return silent(),
    };
    al = oal;

    al_device = al.?.alcOpenDevice(null);
    if (al_device == null) return silent();

    al_context = al.?.alcCreateContext(al_device, null);
    if (al_context == null) return silent();

    _ = al.?.alcMakeContextCurrent(al_context);
    available = true;
    setMasterVolume(0.6);
}

fn silent() void {
    available = false;
    std.debug.print("[Audio] Failed to initialize OpenAL context, running silent\n", .{});
}

pub fn setMasterVolume(vol: f32) void {
    if (available and al != null) {
        al.?.alListenerf(AL_GAIN, vol);
    }
}

pub fn deinit() void {
    if (available and al != null) {
        _ = al.?.alcMakeContextCurrent(null);
        if (al_context) |ctx| al.?.alcDestroyContext(ctx);
        if (al_device) |dev| _ = al.?.alcCloseDevice(dev);
    }
    if (dynlib) |*dl| dl.close();
    sound_arena.deinit();
}

pub fn createSoundFromPcm(samples: []const i16, channels: i32, sample_rate: i32) ?*Sound {
    if (!available or al == null) return null;
    var sound = sound_allocator.create(Sound) catch return null;
    sound.* = .{};

    al.?.alGenBuffers(1, @ptrCast(&sound.buffer));
    const fmt: c_int = if (channels == 1) AL_FORMAT_MONO16 else AL_FORMAT_STEREO16;
    const size: c_int = @intCast(samples.len * @sizeOf(i16));
    al.?.alBufferData(sound.buffer, fmt, samples.ptr, size, sample_rate);

    al.?.alGenSources(1, @ptrCast(&sound.source));
    al.?.alSourcei(sound.source, AL_BUFFER, @intCast(sound.buffer));
    al.?.alSourcef(sound.source, AL_GAIN, sound.volume);
    sound.loaded = true;

    return sound;
}

pub fn createSoundFromMp3Memory(mp3_data: []const u8) ?*Sound {
    if (!available or al == null) return null;
    var channels: c_int = 0;
    var sample_rate: c_int = 0;
    var output_ptr: [*c]i16 = null;
    var sample_count: usize = 0;

    const res = c.decode_mp3_memory(
        mp3_data.ptr,
        mp3_data.len,
        &output_ptr,
        &channels,
        &sample_rate,
        &sample_count,
    );
    if (res != 0 or output_ptr == null) {
        std.debug.print("[Audio] MP3 decode failed\n", .{});
        return null;
    }
    defer c.free_mp3_memory(output_ptr);

    return createSoundFromPcm(output_ptr[0..sample_count], channels, sample_rate);
}

pub fn createDialogueSound(allocator: std.mem.Allocator, pitch: f32, weight: f32, volume: f32) ?*Sound {
    const clamped_weight = std.math.clamp(weight, 0.2, 3.0);
    const p = pitch / std.math.pow(f32, clamped_weight, 0.4);
    const p_drop = 60.0 * clamped_weight;
    const dur = 0.038 * std.math.pow(f32, clamped_weight, 0.3);
    const decay_rate = 4.5 / std.math.pow(f32, clamped_weight, 0.3);
    const warmth = std.math.clamp(0.15 * clamped_weight, 0.0, 0.4);

    const sample_rate: i32 = 44100;
    const num_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * dur);
    if (num_samples == 0) return null;

    var samples = allocator.alloc(i16, num_samples) catch return null;
    defer allocator.free(samples);

    const f0 = p;
    const f1 = p - p_drop;
    const attack: f32 = 0.0025;
    const duration: f32 = @max(attack, dur);
    const h1 = std.math.clamp(1.0 - warmth - 0.03, 0.0, 1.0);
    const h2 = warmth;
    const h3: f32 = 0.03;

    for (0..num_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const phase = 2.0 * std.math.pi * (f0 * t + 0.5 * (f1 - f0) * (t * t / duration));
        const raw = h1 * @sin(phase) + h2 * @sin(phase * 2.0) + h3 * @sin(phase * 3.0);
        var env: f32 = undefined;
        if (t < attack) {
            env = 0.5 * (1.0 - @cos(std.math.pi * t / attack));
        } else {
            const decay_progress = (t - attack) / (duration - attack);
            env = @exp(-decay_progress * decay_rate) * (1.0 - decay_progress * 0.2);
        }
        const val = std.math.clamp(raw * env * volume, -1.0, 1.0);
        samples[i] = @intFromFloat(val * 32767.0);
    }

    return createSoundFromPcm(samples, 1, sample_rate);
}

pub fn createRobotSound(allocator: std.mem.Allocator, pitch: f32, duration: f32, volume: f32) ?*Sound {
    const sample_rate: i32 = 44100;
    const num_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * duration);
    if (num_samples == 0) return null;

    var samples = allocator.alloc(i16, num_samples) catch return null;
    defer allocator.free(samples);

    for (0..num_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const phase = 2.0 * std.math.pi * pitch * t;
        const s = @sin(phase);
        const sq: f32 = if (s >= 0) 1.0 else -1.0;
        const saw: f32 = 2.0 * (pitch * t - @floor(pitch * t + 0.5));
        const raw = sq * 0.65 + saw * 0.35;
        const env = @exp(-t * 28.0);
        const val = std.math.clamp(raw * env * volume, -1.0, 1.0);
        samples[i] = @intFromFloat(val * 32767.0);
    }

    return createSoundFromPcm(samples, 1, sample_rate);
}

pub fn createSuccessJingle(allocator: std.mem.Allocator, volume: f32) ?*Sound {
    const sample_rate: i32 = 44100;
    const notes = [_]f32{ 523.25, 659.25, 783.99, 1046.50 };
    const note_dur: f32 = 0.12;
    const last_dur: f32 = 0.38;
    const total_dur: f32 = note_dur * 3.0 + last_dur;
    const total_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * total_dur);

    var samples = allocator.alloc(i16, total_samples) catch return null;
    defer allocator.free(samples);
    @memset(samples, 0);

    for (notes, 0..) |freq, n| {
        const dur = if (n == notes.len - 1) last_dur else note_dur;
        const decay: f32 = if (n == notes.len - 1) 4.5 else 8.0;
        const start_sample: usize = @intFromFloat(@as(f32, @floatFromInt(n)) * note_dur * @as(f32, @floatFromInt(sample_rate)));
        const count: usize = @intFromFloat(dur * @as(f32, @floatFromInt(sample_rate)));

        var i: usize = 0;
        while (i < count and (start_sample + i) < total_samples) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            const phase = 2.0 * std.math.pi * freq * t;
            const wave = @sin(phase) + 0.33 * @sin(phase * 3.0) + 0.15 * @sin(phase * 5.0);
            const env = @exp(-t * decay);
            const val = std.math.clamp(wave * env * volume * 0.8, -1.0, 1.0);
            samples[start_sample + i] = @intFromFloat(val * 32767.0);
        }
    }

    return createSoundFromPcm(samples, 1, sample_rate);
}

pub fn createNesExplosion(allocator: std.mem.Allocator, duration: f32, volume: f32) ?*Sound {
    const sample_rate: i32 = 44100;
    const total_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * duration);
    var samples = allocator.alloc(i16, total_samples) catch return null;
    defer allocator.free(samples);

    var shift_reg: u16 = 1;
    var sample_hold: f32 = 0.0;
    var timer: i32 = 0;

    for (0..total_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const clock_div: i32 = 10 + @as(i32, @intFromFloat(t * 70.0));

        timer += 1;
        if (timer >= clock_div) {
            timer = 0;
            const feedback: u16 = (shift_reg & 1) ^ ((shift_reg >> 1) & 1);
            shift_reg = (shift_reg >> 1) | (feedback << 14);
            sample_hold = if ((shift_reg & 1) == 1) 1.0 else -1.0;
        }

        const env = @exp(-t * 3.8);
        const val = std.math.clamp(sample_hold * env * volume, -1.0, 1.0);
        samples[i] = @intFromFloat(val * 32767.0);
    }

    return createSoundFromPcm(samples, 1, sample_rate);
}

pub fn createNotBadJingle(allocator: std.mem.Allocator, volume: f32) ?*Sound {
    const sample_rate: i32 = 44100;
    const notes = [_]f32{ 466.16, 369.99, 277.18 };
    const note_dur: f32 = 0.053;
    const last_dur: f32 = 0.15;
    const total_dur: f32 = note_dur * 2.0 + last_dur;
    const total_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * total_dur);

    var samples = allocator.alloc(i16, total_samples) catch return null;
    defer allocator.free(samples);
    @memset(samples, 0);

    for (notes, 0..) |freq, n| {
        const dur = if (n == notes.len - 1) last_dur else note_dur;
        const decay: f32 = if (n == notes.len - 1) 10.5 else 16.5;
        const start_sample: usize = @intFromFloat(@as(f32, @floatFromInt(n)) * note_dur * @as(f32, @floatFromInt(sample_rate)));
        const count: usize = @intFromFloat(dur * @as(f32, @floatFromInt(sample_rate)));

        var i: usize = 0;
        while (i < count and (start_sample + i) < total_samples) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            const phase = 2.0 * std.math.pi * freq * t;
            const s = @sin(phase);
            const sq: f32 = if (s >= 0) 1.0 else -1.0;
            const sine = s;
            const wave = sq * 0.4 + sine * 0.6;
            const env = @exp(-t * decay);
            const val = std.math.clamp(wave * env * volume * 0.85, -1.0, 1.0);
            samples[start_sample + i] = @intFromFloat(val * 32767.0);
        }
    }

    return createSoundFromPcm(samples, 1, sample_rate);
}
