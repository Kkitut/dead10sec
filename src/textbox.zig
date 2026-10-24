const std = @import("std");
const types = @import("types.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const renderer2d = @import("renderer2d.zig");
const scene = @import("scene.zig");
const audio = @import("audio.zig");
const Sound = audio.Sound;

pub const TextFx = enum {
    None,
    Wave,
    Shake,
};

pub const ScriptPage = struct {
    speaker: ?[]const u8 = null,
    text: []const u8,
    bg_command: ?[]const u8 = null,
    fx: TextFx = .None,
};

pub const TextBox = struct {
    font: *Font,
    x: f32,
    y: f32,
    max_width: f32,
    box_h: f32,
    color: [4]f32,
    cps: f32 = 60.0,

    pages: std.ArrayList(ScriptPage),
    page: usize = 0,
    shown: f32 = 0,
    blink: f32 = 0,
    time: f32 = 0,

    visible: bool = false,
    is_ended: bool = false,

    hayul_sound: ?*Sound = null,
    robot_sound: ?*Sound = null,

    on_complete: ?*const fn () void = null,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        font: *Font,
        x: f32,
        y: f32,
        max_w: f32,
        box_h: f32,
        color: [4]f32,
    ) TextBox {
        return .{
            .allocator = allocator,
            .font = font,
            .x = x,
            .y = y,
            .max_width = max_w,
            .box_h = box_h,
            .color = color,
            .pages = .empty,
        };
    }

    pub fn load(self: *TextBox, script: []const []const u8) void {
        self.pages.clearRetainingCapacity();
        var current_speaker: ?[]const u8 = null;
        var pending_bg: ?[]const u8 = null;

        for (script) |raw_line| {
            var line = std.mem.trim(u8, raw_line, " \r\n\t");
            if (line.len == 0 or std.mem.eql(u8, line, "---")) continue;

            if (line[0] == '@') {
                const space_idx = std.mem.indexOfScalar(u8, line, ' ');
                const cmd = if (space_idx) |idx| line[1..idx] else line[1..];
                const arg = if (space_idx) |idx| std.mem.trim(u8, line[idx + 1 ..], " \r\n\t") else "";

                if (std.ascii.eqlIgnoreCase(cmd, "bg")) {
                    pending_bg = arg;
                } else if (std.ascii.eqlIgnoreCase(cmd, "name")) {
                    current_speaker = if (arg.len > 0) arg else null;
                }
                continue;
            }

            var speaker = current_speaker;
            var text = line;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                if (colon > 0 and colon < 16 and !std.mem.containsAtLeast(u8, line[0..colon], 1, " ")) {
                    speaker = std.mem.trim(u8, line[0..colon], " ");
                    text = std.mem.trimStart(u8, line[colon + 1 ..], " ");
                }
            }

            var fx = TextFx.None;
            if (std.mem.startsWith(u8, text, "[s]") and std.mem.endsWith(u8, text, "[/]")) {
                fx = .Shake;
                text = text[3 .. text.len - 3];
            } else if (std.mem.startsWith(u8, text, "[w]") and std.mem.endsWith(u8, text, "[/]")) {
                fx = .Wave;
                text = text[3 .. text.len - 3];
            }

            self.pages.append(self.allocator, .{
                .speaker = speaker,
                .text = text,
                .bg_command = pending_bg,
                .fx = fx,
            }) catch {};
            pending_bg = null;
        }

        self.page = 0;
        self.shown = 0;
        self.blink = 0;
        self.is_ended = false;
        self.visible = true;

        if (self.pages.items.len > 0 and self.pages.items[0].bg_command != null) {
            scene.setBackground(self.pages.items[0].bg_command.?);
        }
    }

    fn pageCharCount(self: *TextBox, p: usize) usize {
        if (p >= self.pages.items.len) return 0;
        const text = self.pages.items[p].text;
        var count: usize = 0;
        var iter = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
        while (iter.nextCodepoint()) |_| count += 1;
        return count;
    }

    pub fn isComplete(self: *TextBox) bool {
        return self.shown >= @as(f32, @floatFromInt(self.pageCharCount(self.page)));
    }

    pub fn blinkOn(self: *TextBox) bool {
        return self.visible and self.isComplete() and @rem(self.blink, 1.0) < 0.6;
    }

    pub fn advance(self: *TextBox) void {
        if (!self.visible or self.is_ended or self.pages.items.len == 0) return;

        const max_chars = self.pageCharCount(self.page);
        if (self.shown < @as(f32, @floatFromInt(max_chars))) {
            self.shown = @floatFromInt(max_chars);
        } else if (self.page + 1 < self.pages.items.len) {
            self.page += 1;
            self.shown = 0;
            if (self.pages.items[self.page].bg_command) |bg| {
                scene.setBackground(bg);
            }
        } else {
            self.is_ended = true;
            self.visible = false;
            if (self.on_complete) |cb| cb();
        }
    }

    pub fn skip(self: *TextBox) void {
        if (!self.visible or self.is_ended) return;
        self.is_ended = true;
        self.visible = false;
        if (self.on_complete) |cb| cb();
    }

    pub fn update(self: *TextBox, dt: f32) void {
        if (!self.visible or self.is_ended or self.pages.items.len == 0) return;

        self.time += dt;
        self.blink += dt;

        const max_chars = self.pageCharCount(self.page);
        if (self.shown < @as(f32, @floatFromInt(max_chars))) {
            const prev: usize = @intFromFloat(self.shown);
            self.shown = @min(@as(f32, @floatFromInt(max_chars)), self.shown + dt * self.cps);
            const curr: usize = @intFromFloat(self.shown);

            if (curr > prev) {
                const line = self.pages.items[self.page];
                var sound = self.hayul_sound;
                if (line.speaker) |spk| {
                    if (std.mem.indexOf(u8, spk, "경보") != null) {
                        sound = self.robot_sound;
                    }
                }
                if (sound) |snd| {
                    if (curr % 2 == 0 or curr == 1) {
                        snd.play();
                    }
                }
            }
        }
    }

    pub fn draw(self: *TextBox) void {
        if (!self.visible or self.is_ended or self.pages.items.len == 0) return;
        const cur = self.pages.items[self.page];

        if (cur.speaker) |spk| {
            var buf: [64]u8 = undefined;
            const spk_text = std.fmt.bufPrint(&buf, "[{s}]", .{spk}) catch spk;
            renderer2d.drawText(self.font, spk_text, .{ self.x, self.y - 18 }, self.color, 1.0, false);
        }

        const count: usize = @intFromFloat(self.shown);
        var sub_end: usize = 0;
        var char_idx: usize = 0;
        var iter = (std.unicode.Utf8View.init(cur.text) catch return).iterator();
        while (iter.nextCodepointSlice()) |slice| {
            if (char_idx >= count) break;
            sub_end += slice.len;
            char_idx += 1;
        }
        const visible_text = cur.text[0..sub_end];

        const full_w = renderer2d.measureText(self.font, cur.text, 1.0);
        const sx = @floor(self.x + (self.max_width - full_w) / 2.0);
        const base_y = @floor(self.y + (self.box_h + self.font.ascent_px - self.font.descent_px) / 2.0);

        switch (cur.fx) {
            .None => renderer2d.drawText(self.font, visible_text, .{ sx, base_y }, self.color, 1.0, false),
            .Wave => renderer2d.drawTextWave(self.font, visible_text, .{ sx, base_y }, self.color, self.time, 2.5, 6.0, 1.0),
            .Shake => renderer2d.drawTextShake(self.font, visible_text, .{ sx, base_y }, self.color, self.time, 1.2, 1.0),
        }
    }
};
