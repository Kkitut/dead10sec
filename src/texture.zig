const std = @import("std");
const c = @import("c");
const assets = @import("assets.zig");

pub const Texture = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    sampler: c.VkSampler = null,
    descriptor: c.VkDescriptorSet = null,
    width: u32 = 0,
    height: u32 = 0,
};

pub var textures: std.ArrayList(Texture) = .empty;
pub var white_tex_id: usize = 0;
pub var texture_allocator: std.mem.Allocator = undefined;

var engine_ptr: *anyopaque = undefined;
var create_tex_fn: *const fn (ctx: *anyopaque, pixels: []const u8, width: u32, height: u32) Texture = undefined;
var update_tex_fn: *const fn (ctx: *anyopaque, tex: Texture, pixels: []const u8, width: u32, height: u32) void = undefined;

pub fn init(
    allocator: std.mem.Allocator,
    engine: *anyopaque,
    create_fn: *const fn (ctx: *anyopaque, pixels: []const u8, width: u32, height: u32) Texture,
    update_fn: *const fn (ctx: *anyopaque, tex: Texture, pixels: []const u8, width: u32, height: u32) void,
) !void {
    texture_allocator = allocator;
    textures = .empty;
    engine_ptr = engine;
    create_tex_fn = create_fn;
    update_tex_fn = update_fn;

    const white_px = [_]u8{ 255, 255, 255, 255 };
    white_tex_id = try loadRaw(&white_px, 1, 1);
}

pub fn loadRaw(pixels: []const u8, width: u32, height: u32) !usize {
    const tex = create_tex_fn(engine_ptr, pixels, width, height);
    const id = textures.items.len;
    try textures.append(texture_allocator, tex);
    return id;
}

pub fn loadPngMemory(png_data: []const u8) !usize {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load_from_memory(
        png_data.ptr,
        @intCast(png_data.len),
        &w,
        &h,
        &channels,
        4,
    );
    if (pixels == null) {
        return error.PngDecodeFailed;
    }
    defer c.stbi_image_free(pixels);

    const size: usize = @intCast(w * h * 4);
    return loadRaw(pixels[0..size], @intCast(w), @intCast(h));
}

pub fn loadByPath(path: []const u8) !usize {
    if (assets.getImageData(path)) |data| {
        return loadPngMemory(data);
    }
    return error.FileNotFound;
}

pub fn loadFontAtlas(gray: []const u8, width: u32, height: u32) !usize {
    const total = width * height;
    var rgba = try texture_allocator.alloc(u8, total * 4);
    defer texture_allocator.free(rgba);

    for (0..total) |i| {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = gray[i];
    }

    return loadRaw(rgba, width, height);
}

pub fn updateFontAtlas(id: usize, gray: []const u8, width: u32, height: u32) !void {
    if (id >= textures.items.len) return;
    const total = width * height;
    var rgba = try texture_allocator.alloc(u8, total * 4);
    defer texture_allocator.free(rgba);

    for (0..total) |i| {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = gray[i];
    }

    update_tex_fn(engine_ptr, textures.items[id], rgba, width, height);
}
