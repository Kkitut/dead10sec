const std = @import("std");
const types = @import("types.zig");
const Sprite = types.Sprite;
const texture_mod = @import("texture.zig");
const assets = @import("assets.zig");
const renderer2d = @import("renderer2d.zig");

pub var bg_sprite: Sprite = .{};
var white_tex: usize = 0;
var cache: std.StringHashMap(usize) = undefined;

pub fn init(allocator: std.mem.Allocator, vw: f32, vh: f32, white_id: usize) !void {
    white_tex = white_id;
    cache = std.StringHashMap(usize).init(allocator);

    bg_sprite = Sprite{
        .pos = .{ 0, 0 },
        .size = .{ vw, vh },
        .layer = -1,
        .texture_id = white_tex,
        .color = types.fromSrgb(0x21, 0x2E, 0x40, 1.0),
        .visible = true,
    };
    try renderer2d.add(bg_sprite);
}

pub fn setBackground(path: []const u8) void {
    if (path.len == 0) return;

    if (std.ascii.eqlIgnoreCase(path, "none") or
        std.ascii.eqlIgnoreCase(path, "default") or
        std.ascii.eqlIgnoreCase(path, "clear"))
    {
        bg_sprite.texture_id = white_tex;
        bg_sprite.color = types.fromSrgb(0x21, 0x2E, 0x40, 1.0);
        updateBgInList();
        return;
    }

    const hex_str = if (path.len > 0 and path[0] == '#') path[1..] else path;
    if (hex_str.len == 6 or hex_str.len == 8) {
        if (std.fmt.parseInt(u32, hex_str, 16)) |val| {
            bg_sprite.texture_id = white_tex;
            if (hex_str.len == 6) {
                const r: u8 = @intCast((val >> 16) & 0xFF);
                const g: u8 = @intCast((val >> 8) & 0xFF);
                const b: u8 = @intCast(val & 0xFF);
                bg_sprite.color = types.fromSrgb(r, g, b, 1.0);
            } else {
                const r: u8 = @intCast((val >> 24) & 0xFF);
                const g: u8 = @intCast((val >> 16) & 0xFF);
                const b: u8 = @intCast((val >> 8) & 0xFF);
                const a: f32 = @as(f32, @floatFromInt(val & 0xFF)) / 255.0;
                bg_sprite.color = types.fromSrgb(r, g, b, a);
            }
            updateBgInList();
            return;
        } else |_| {}
    }

    if (getOrLoadTexture(path)) |id| {
        bg_sprite.texture_id = id;
        bg_sprite.color = .{ 1, 1, 1, 1 };
        updateBgInList();
    }
}

pub fn getOrLoadTexture(path: []const u8) ?usize {
    if (cache.get(path)) |id| return id;

    const id = texture_mod.loadByPath(path) catch return null;
    cache.put(path, id) catch {};
    return id;
}

pub fn preloadAll() void {
    for (assets.all_images) |entry| {
        _ = getOrLoadTexture(entry.name);
    }
}

fn updateBgInList() void {
    if (renderer2d.draw_list.items.len > 0) {
        renderer2d.draw_list.items[0] = bg_sprite;
    }
}
