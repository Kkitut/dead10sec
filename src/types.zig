const std = @import("std");

pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
};

pub const quad_vertices = [_]Vertex{
    .{ .pos = .{ 0, 1 }, .uv = .{ 0, 0 } },
    .{ .pos = .{ 1, 1 }, .uv = .{ 1, 0 } },
    .{ .pos = .{ 1, 0 }, .uv = .{ 1, 1 } },

    .{ .pos = .{ 0, 1 }, .uv = .{ 0, 0 } },
    .{ .pos = .{ 1, 0 }, .uv = .{ 1, 1 } },
    .{ .pos = .{ 0, 0 }, .uv = .{ 0, 1 } },
};

pub const Push = extern struct {
    color: [4]f32,
    screen: [2]f32,
    pos: [2]f32,
    size: [2]f32,
    rot: f32 = 0,
    scale: f32 = 1,
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 1, 1 },
};

pub const Sprite = struct {
    pos: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    layer: i32 = 0,
    texture_id: usize = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    visible: bool = true,
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 1, 1 },
    rot: f32 = 0,
    scale: f32 = 1,
};

pub const PixelViewport = struct {
    virtual_width: i32,
    virtual_height: i32,
    integer_scale: bool = false,
    scale: f32 = 1.0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    view_width: i32,
    view_height: i32,

    pub fn init(vw: i32, vh: i32) PixelViewport {
        return .{
            .virtual_width = vw,
            .virtual_height = vh,
            .view_width = vw,
            .view_height = vh,
        };
    }

    pub fn update(self: *PixelViewport, fb_w: i32, fb_h: i32) void {
        if (fb_w <= 0 or fb_h <= 0) return;
        const sw = @as(f32, @floatFromInt(fb_w)) / @as(f32, @floatFromInt(self.virtual_width));
        const sh = @as(f32, @floatFromInt(fb_h)) / @as(f32, @floatFromInt(self.virtual_height));
        var s = @min(sw, sh);
        if (self.integer_scale and s >= 1.0) {
            s = @floor(s);
        }
        self.scale = s;
        self.view_width = @intFromFloat(@as(f32, @floatFromInt(self.virtual_width)) * s);
        self.view_height = @intFromFloat(@as(f32, @floatFromInt(self.virtual_height)) * s);
        self.offset_x = @divTrunc(fb_w - self.view_width, 2);
        self.offset_y = @divTrunc(fb_h - self.view_height, 2);
    }
};

fn toLinear(c_val: f32) f32 {
    return if (c_val <= 0.04045)
        c_val / 12.92
    else
        std.math.pow(f32, (c_val + 0.055) / 1.055, 2.4);
}

pub fn fromSrgb(r: u8, g: u8, b: u8, a: f32) [4]f32 {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    return .{
        toLinear(rf),
        toLinear(gf),
        toLinear(bf),
        a,
    };
}


