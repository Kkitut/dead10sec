const std = @import("std");
const types = @import("types.zig");
const Sprite = types.Sprite;
const font_mod = @import("font.zig");
const Font = font_mod.Font;

pub var draw_list: std.ArrayList(Sprite) = .empty;
pub var frame_list: std.ArrayList(Sprite) = .empty;
var r2d_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    r2d_allocator = allocator;
    draw_list = .empty;
    frame_list = .empty;
}

pub fn add(sprite: Sprite) !void {
    try draw_list.append(r2d_allocator, sprite);
}

pub fn clear() void {
    draw_list.clearRetainingCapacity();
}

pub fn addFrame(sprite: Sprite) void {
    frame_list.append(r2d_allocator, sprite) catch {};
}

pub fn drawChar(font: *Font, codepoint: u32, pos: [2]f32, color: [4]f32, scale: f32, italic: bool) f32 {
    font.addChar(codepoint, italic);
    const g = font.tryGetGlyph(codepoint, italic) orelse return 0;

    if (g.width > 0 and g.height > 0) {
        const s = Sprite{
            .color = color,
            .pos = .{
                @floor(pos[0] + @as(f32, @floatFromInt(g.bearing_x)) * scale),
                @floor(pos[1] - @as(f32, @floatFromInt(g.bearing_y)) * scale),
            },
            .size = .{
                @as(f32, @floatFromInt(g.width)) * scale,
                @as(f32, @floatFromInt(g.height)) * scale,
            },
            .texture_id = font.texture_id,
            .uv0 = .{ g.u0, 1.0 - g.v1 },
            .uv1 = .{ g.u1, 1.0 - g.v0 },
            .layer = 100,
            .visible = true,
        };
        addFrame(s);
    }

    return @as(f32, @floatFromInt(g.advance)) * scale;
}

pub fn drawText(font: *Font, text: []const u8, pos: [2]f32, color: [4]f32, scale: f32, italic: bool) void {
    var x = pos[0];
    var y = pos[1];
    const line_height = @as(f32, @floatFromInt(font.size)) * scale * 1.2;

    var iter = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            x = pos[0];
            y += line_height;
            continue;
        }
        x += drawChar(font, cp, .{ x, y }, color, scale, italic);
    }
}

pub fn drawTextOutlined(
    font: *Font,
    text: []const u8,
    pos: [2]f32,
    text_color: [4]f32,
    outline_color: [4]f32,
    outline_radius: i32,
    scale: f32,
    italic: bool,
) void {
    var oy = -outline_radius;
    while (oy <= outline_radius) : (oy += 1) {
        var ox = -outline_radius;
        while (ox <= outline_radius) : (ox += 1) {
            if (ox == 0 and oy == 0) continue;
            if (ox * ox + oy * oy <= (outline_radius * outline_radius) + 1) {
                drawText(font, text, .{ pos[0] + @as(f32, @floatFromInt(ox)), pos[1] + @as(f32, @floatFromInt(oy)) }, outline_color, scale, italic);
            }
        }
    }
    drawText(font, text, pos, text_color, scale, italic);
}

pub fn measureText(font: *Font, text: []const u8, scale: f32) f32 {
    var max_w: f32 = 0;
    var cur_w: f32 = 0;

    var iter = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            if (cur_w > max_w) max_w = cur_w;
            cur_w = 0;
            continue;
        }
        font.addChar(cp, false);
        if (font.tryGetGlyph(cp, false)) |g| {
            cur_w += @as(f32, @floatFromInt(g.advance)) * scale;
        }
    }
    return @max(max_w, cur_w);
}

pub fn drawTextWave(font: *Font, text: []const u8, pos: [2]f32, color: [4]f32, time: f32, amp: f32, freq: f32, scale: f32) void {
    var x = pos[0];
    var i: usize = 0;

    var iter = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (iter.nextCodepoint()) |cp| : (i += 1) {
        const y_off = @sin(time * freq + @as(f32, @floatFromInt(i)) * 0.5) * amp;
        x += drawChar(font, cp, .{ x, pos[1] + y_off }, color, scale, false);
    }
}

pub fn drawTextShake(font: *Font, text: []const u8, pos: [2]f32, color: [4]f32, time: f32, amp: f32, scale: f32) void {
    var x = pos[0];
    const tick: i64 = @intFromFloat(time * 25.0);
    var i: usize = 0;

    var iter = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (iter.nextCodepoint()) |cp| : (i += 1) {
        const idx_val: i64 = @intCast(i);
        var h1: i64 = (idx_val *% 73856093) ^ (tick *% 19349663) ^ 11;
        h1 ^= h1 >> 13;
        h1 *%= 1274126177;
        h1 ^= h1 >> 16;

        var h2: i64 = (idx_val *% 73856093) ^ (tick *% 19349663) ^ 73;
        h2 ^= h2 >> 13;
        h2 *%= 1274126177;
        h2 ^= h2 >> 16;

        const ox = @as(f32, @floatFromInt((h1 & 7) - 3)) * (amp / 3.0);
        const oy = @as(f32, @floatFromInt((h2 & 7) - 3)) * (amp / 3.0);

        x += drawChar(font, cp, .{ x + ox, pos[1] + oy }, color, scale, false);
    }
}
