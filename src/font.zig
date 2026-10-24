const std = @import("std");
const c = @import("c");
const texture = @import("texture.zig");

pub const Glyph = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    width: i32,
    height: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
};

pub const Font = struct {
    font_info: c.stbtt_fontinfo,
    scale: f32,
    size: i32,
    ascent_px: f32,
    descent_px: f32,

    atlas: []u8,
    atlas_w: u32 = 512,
    atlas_h: u32 = 512,
    pen_x: u32 = 0,
    pen_y: u32 = 0,
    row_h: u32 = 0,

    texture_id: usize,
    glyphs: std.AutoHashMap(u32, Glyph),
    allocator: std.mem.Allocator,

    fn getKey(codepoint: u32, italic: bool) u32 {
        return if (italic) (codepoint | (1 << 24)) else codepoint;
    }

    pub fn init(allocator: std.mem.Allocator, ttf_data: []const u8, size: i32) !*Font {
        const font = try allocator.create(Font);
        font.allocator = allocator;
        font.size = size;

        if (c.stbtt_InitFont(&font.font_info, ttf_data.ptr, 0) == 0) {
            return error.FontInitFailed;
        }

        font.scale = c.stbtt_ScaleForPixelHeight(&font.font_info, @floatFromInt(size));

        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&font.font_info, &ascent, &descent, &line_gap);
        font.ascent_px = @as(f32, @floatFromInt(ascent)) * font.scale;
        font.descent_px = -@as(f32, @floatFromInt(descent)) * font.scale;

        font.atlas_w = 512;
        font.atlas_h = 512;
        font.pen_x = 0;
        font.pen_y = 0;
        font.row_h = 0;

        const total_px = font.atlas_w * font.atlas_h;
        font.atlas = try allocator.alloc(u8, total_px);
        @memset(font.atlas, 0);

        font.texture_id = try texture.loadFontAtlas(font.atlas, font.atlas_w, font.atlas_h);
        font.glyphs = std.AutoHashMap(u32, Glyph).init(allocator);

        return font;
    }

    pub fn addChar(self: *Font, codepoint: u32, italic: bool) void {
        const key = getKey(codepoint, italic);
        if (self.glyphs.contains(key)) return;

        var advance: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.font_info, @intCast(codepoint), &advance, &lsb);

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetCodepointBitmapBox(&self.font_info, @intCast(codepoint), self.scale, self.scale, &x0, &y0, &x1, &y1);

        const gw_raw: i32 = x1 - x0;
        const gh_raw: i32 = y1 - y0;

        if (gw_raw > 0 and gh_raw > 0) {
            const shear: f32 = if (italic) 0.22 else 0.0;
            const max_shift: i32 = if (italic) @intFromFloat(@round(@as(f32, @floatFromInt(gh_raw - 1)) * shear)) else 0;
            const gw: u32 = @intCast(gw_raw + max_shift);
            const gh: u32 = @intCast(gh_raw);

            if (self.pen_x + gw >= self.atlas_w) {
                self.pen_x = 0;
                self.pen_y += self.row_h;
                self.row_h = 0;
            }

            if (self.pen_y + gh >= self.atlas_h) {
                return;
            }

            var glyph_buf: [128 * 128]u8 = undefined;
            if (gw_raw * gh_raw <= glyph_buf.len) {
                c.stbtt_MakeCodepointBitmap(
                    &self.font_info,
                    &glyph_buf,
                    gw_raw,
                    gh_raw,
                    gw_raw,
                    self.scale,
                    self.scale,
                    @intCast(codepoint),
                );

                for (0..gh) |y| {
                    const shift: usize = if (italic) @intFromFloat(@round(@as(f32, @floatFromInt(gh_raw - 1 - @as(i32, @intCast(y)))) * shear)) else 0;
                    for (0..@as(usize, @intCast(gw_raw))) |x| {
                        const src_val = glyph_buf[y * @as(usize, @intCast(gw_raw)) + x];
                        const dst_idx = (self.pen_y + y) * self.atlas_w + (self.pen_x + shift + x);
                        if (dst_idx < self.atlas.len) {
                            self.atlas[dst_idx] = src_val;
                        }
                    }
                }

                texture.updateFontAtlas(self.texture_id, self.atlas, self.atlas_w, self.atlas_h) catch {};
            }

            if (gh > self.row_h) self.row_h = gh;

            const u_0 = @as(f32, @floatFromInt(self.pen_x)) / @as(f32, @floatFromInt(self.atlas_w));
            const v_0 = @as(f32, @floatFromInt(self.pen_y)) / @as(f32, @floatFromInt(self.atlas_h));
            const u_1 = @as(f32, @floatFromInt(self.pen_x + gw)) / @as(f32, @floatFromInt(self.atlas_w));
            const v_1 = @as(f32, @floatFromInt(self.pen_y + gh)) / @as(f32, @floatFromInt(self.atlas_h));

            const g = Glyph{
                .u0 = u_0,
                .v0 = v_0,
                .u1 = u_1,
                .v1 = v_1,
                .width = @intCast(gw),
                .height = @intCast(gh),
                .bearing_x = x0,
                .bearing_y = -y0,
                .advance = @intFromFloat(@as(f32, @floatFromInt(advance)) * self.scale),
            };

            self.glyphs.put(key, g) catch {};
            self.pen_x += gw + 1;
        } else {
            const g = Glyph{
                .u0 = 0,
                .v0 = 0,
                .u1 = 0,
                .v1 = 0,
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @intFromFloat(@as(f32, @floatFromInt(advance)) * self.scale),
            };
            self.glyphs.put(key, g) catch {};
        }
    }

    pub fn tryGetGlyph(self: *Font, codepoint: u32, italic: bool) ?Glyph {
        const key = getKey(codepoint, italic);
        return self.glyphs.get(key);
    }
};
