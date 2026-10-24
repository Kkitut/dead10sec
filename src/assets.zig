const std = @import("std");

pub const shader_vert = @embedFile("shader/vert.spv");
pub const shader_frag = @embedFile("shader/frag.spv");

pub const font_galmuri14 = @embedFile("assets/Galmuri14.ttf");
pub const font_galmuri11_bold = @embedFile("assets/Galmuri11-Bold.ttf");

pub const bgm_call_to_adventure = @embedFile("assets/CalltoAdventure.mp3");

pub const img_bad = @embedFile("assets/Images/bad.png");
pub const img_bads0 = @embedFile("assets/Images/bads0.png");
pub const img_btnpress = @embedFile("assets/Images/btnpress.png");
pub const img_game = @embedFile("assets/Images/game.png");
pub const img_good = @embedFile("assets/Images/good.png");
pub const img_goods0 = @embedFile("assets/Images/goods0.png");
pub const img_hidden = @embedFile("assets/Images/hidden.png");
pub const img_iconmaster = @embedFile("assets/Images/iconmaster.png");
pub const img_iconmusic = @embedFile("assets/Images/iconmusic.png");
pub const img_iconx = @embedFile("assets/Images/iconx.png");
pub const img_intro0 = @embedFile("assets/Images/intro0.png");
pub const img_intro1 = @embedFile("assets/Images/intro1.png");
pub const img_intro2 = @embedFile("assets/Images/intro2.png");
pub const img_intro3 = @embedFile("assets/Images/intro3.png");
pub const img_main = @embedFile("assets/Images/main.png");
pub const img_notbad = @embedFile("assets/Images/notbad.png");
pub const img_thanks = @embedFile("assets/Images/thanks.png");

pub const ImageEntry = struct {
    name: []const u8,
    data: []const u8,
};

pub const all_images = [_]ImageEntry{
    .{ .name = "Images/bad.png", .data = img_bad },
    .{ .name = "Images/bads0.png", .data = img_bads0 },
    .{ .name = "Images/btnpress.png", .data = img_btnpress },
    .{ .name = "Images/game.png", .data = img_game },
    .{ .name = "Images/good.png", .data = img_good },
    .{ .name = "Images/goods0.png", .data = img_goods0 },
    .{ .name = "Images/hidden.png", .data = img_hidden },
    .{ .name = "Images/iconmaster.png", .data = img_iconmaster },
    .{ .name = "Images/iconmusic.png", .data = img_iconmusic },
    .{ .name = "Images/iconx.png", .data = img_iconx },
    .{ .name = "Images/intro0.png", .data = img_intro0 },
    .{ .name = "Images/intro1.png", .data = img_intro1 },
    .{ .name = "Images/intro2.png", .data = img_intro2 },
    .{ .name = "Images/intro3.png", .data = img_intro3 },
    .{ .name = "Images/main.png", .data = img_main },
    .{ .name = "Images/notbad.png", .data = img_notbad },
    .{ .name = "Images/thanks.png", .data = img_thanks },
};

pub fn getImageData(path: []const u8) ?[]const u8 {
    for (all_images) |entry| {
        if (std.mem.eql(u8, entry.name, path)) return entry.data;
        if (std.mem.startsWith(u8, entry.name, "Images/") and std.mem.eql(u8, entry.name["Images/".len..], path)) return entry.data;
        if (std.mem.startsWith(u8, path, "Images/") and std.mem.eql(u8, path["Images/".len..], entry.name)) return entry.data;
    }
    return null;
}
