const std = @import("std");
const c = @import("c");

const types = @import("types.zig");
const Sprite = types.Sprite;
const assets = @import("assets.zig");
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const texture_mod = @import("texture.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const renderer2d = @import("renderer2d.zig");
const scene = @import("scene.zig");
const audio = @import("audio.zig");
const Sound = audio.Sound;
const textbox_mod = @import("textbox.zig");
const TextBox = textbox_mod.TextBox;

pub const GameState = enum {
    Title,
    StoryIntro,
    MiniGame,
    EndingDialog,
    GameOver,
    Result,
};

const VirtualWidth: i32 = 640;
const VirtualHeight: i32 = 360;
const WindowWidth: i32 = 1280;
const WindowHeight: i32 = 720;

var state: GameState = .Title;
var selected_menu: usize = 0;
var show_credits: bool = false;

var game_running: bool = false;
var game_elapsed: f64 = 0;
var idle_time: f64 = 0;
var measured_time: f64 = 0;

var white_flash_alpha: f32 = 0;
var current_ending_title: []const u8 = "";
var current_ending_subtitle: []const u8 = "";
var ending_color: [4]f32 = .{ 1, 1, 1, 1 };

var is_dirty: bool = true;
pub fn requestRender() void {
    is_dirty = true;
}

var cleared_endings: std.StringHashMap(void) = undefined;
const save_file = "cleared.dat";

fn loadClearedEndings(allocator: std.mem.Allocator) void {
    cleared_endings = std.StringHashMap(void).init(allocator);
    const fp = c.fopen(save_file, "r") orelse return;
    defer _ = c.fclose(fp);

    var buf: [256]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) {
        const line = std.mem.sliceTo(&buf, 0);
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len > 0) {
            const dup = allocator.dupe(u8, trimmed) catch continue;
            cleared_endings.put(dup, {}) catch {};
        }
    }
}

fn markEndingCleared(allocator: std.mem.Allocator, key: []const u8) void {
    if (!cleared_endings.contains(key)) {
        const dup = allocator.dupe(u8, key) catch return;
        cleared_endings.put(dup, {}) catch return;

        const fp = c.fopen(save_file, "w") orelse return;
        defer _ = c.fclose(fp);

        var it = cleared_endings.keyIterator();
        while (it.next()) |k| {
            _ = c.fputs(k.*.ptr, fp);
            _ = c.fputs("\n", fp);
        }
    }
}

fn isBonusUnlocked() bool {
    return cleared_endings.contains("bad") and
        cleared_endings.contains("notbad") and
        cleared_endings.contains("true") and
        cleared_endings.contains("idle");
}

var global_engine: *Engine = undefined;
var global_textbox: *TextBox = undefined;
var global_window: ?*c.GLFWwindow = null;

var hayul_sound: ?*Sound = null;
var robot_sound: ?*Sound = null;
var success_sound: ?*Sound = null;
var nes_explosion_sound: ?*Sound = null;
var not_bad_sound: ?*Sound = null;
var bgm_sound: ?*Sound = null;

var mute_mode: audio.MuteMode = .None;
const bgm_base_volume: f32 = 0.2;
const bgm_dialogue_volume: f32 = bgm_base_volume * 0.4;
var current_bgm_vol: f32 = bgm_base_volume;

fn applyMute() void {
    if (mute_mode == .Master) {
        audio.setMasterVolume(0);
        if (bgm_sound) |s| s.setVolume(0);
    } else {
        audio.setMasterVolume(0.6);
        if (mute_mode == .Music) {
            if (bgm_sound) |s| s.setVolume(0);
            current_bgm_vol = 0;
        } else {
            if (bgm_sound) |s| s.setVolume(bgm_base_volume);
            current_bgm_vol = bgm_base_volume;
        }
    }
}

var is_borderless: bool = false;
var saved_win_pos: [2]c_int = .{ 0, 0 };
var saved_win_size: [2]c_int = .{ WindowWidth, WindowHeight };

fn setBorderless(window: *c.GLFWwindow, on: bool) void {
    if (on == is_borderless) return;
    if (on) {
        c.glfwGetWindowPos(window, &saved_win_pos[0], &saved_win_pos[1]);
        c.glfwGetWindowSize(window, &saved_win_size[0], &saved_win_size[1]);

        const monitor = c.glfwGetPrimaryMonitor() orelse return;
        const mode = c.glfwGetVideoMode(monitor) orelse return;
        c.glfwSetWindowMonitor(window, monitor, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
    } else {
        c.glfwSetWindowMonitor(window, null, saved_win_pos[0], saved_win_pos[1], saved_win_size[0], saved_win_size[1], 0);
    }
    is_borderless = on;
    requestRender();
}

const intro_script = [_][]const u8{
    "@bg Images/intro0.png",
    "하교 중인 고2 이하율.",
    "@bg Images/intro1.png",
    "갑자기 길거리에서 요란한 경보가 울리기 시작한다.",
    "@bg Images/intro2.png",
    "@name 경보 장치",
    "\"ㅈ됐씁니다. 이 타이머로 10초 못 맞추면 핵폭탄 다 터짐.\"",
    "@name 이하율",
    "\"씨발 왜요? 왜 제가 해야하는거죠??\"",
    "@bg Images/intro3.png",
    "@name 경보 장치",
    "\"ㅉㅉ어쩔 제작자가 니가 하래요.\"",
    "@name 이하율",
    "[s]\"ㅆㅂ.\"[/]",
};

const bonus_script = [_][]const u8{
    "@bg Images/thanks.png",
    "@name 제작자",
    "\"그래서 이거 왜 만들었냐고요?\"",
    "@name 제작자",
    "\"나도몰러요 ㅆㅂ\"",
    "@name 제작자",
    "\"걍 불칸으로뭐하나만들어보고싶었던거임\"",
    "@name 제작자",
    "\"일단 플레이 매우감사;;\"",
    "@name 제작자",
    "\"ㅂㅂ\"",
    "@name 제작자",
    "\"...\"",
};

const true_end_script = [_][]const u8{
    "@name 경보 장치",
    "\"측정 성공. 핵폭탄 발사를 취소합니다.\"",
    "@name 이하율",
    "@bg Images/goods0.png",
    "\"아, 살았다.\"",
    "@name 경보 장치",
    "\"축하드립니다. 인류를 구하셨습니다.\"",
    "@name 이하율",
    "@bg Images/good.png",
    "\"근데 너 그냥 타이머 만들면 되는 거 아니었냐?\"",
    "@name 경보 장치",
    "\"……\"",
};

const notbad_end_script = [_][]const u8{
    "@name 경보 장치",
    "\"측정 결과. 허용 오차를 초과하지 않았습니다.\"",
    "@name 이하율",
    "\"오, 성공?\"",
    "@name 경보 장치",
    "\"네. 핵폭탄 발사를 취소합니다.\"",
    "@name 이하율",
    "\"휴……\"",
    "@bg Images/notbad.png",
    "잠시 후, 뉴스 속보가 화면에 뜬다.",
    "@name 속보",
    "[w]세계 주요 도시 중 한 곳에서 핵폭발 발생.[/]",
    "@name 이하율",
    "\"……어?\"",
    "@name 경보 장치",
    "\"측정 오차로 인해 이미 발사된 핵폭탄 한 발을 회수하지 못했습니다.\"",
    "@name 이하율",
    "\"아니 씨발.\"",
    "@name 경보 장치",
    "\"그래도 세계는 구했습니다.\"",
    "@name 이하율",
    "[s]\"도시 하나 날아갔잖아!!!!!\"[/]",
};

const bad_end_script = [_][]const u8{
    "@name 경보 장치",
    "\"측정 실패. 핵폭탄을 발사합니다.\"",
    "@name 이하율",
    "@bg Images/bads0.png",
    "[s]\"아니 씨발 잠깐만—\"[/]",
};

const idle_end_script = [_][]const u8{
    "@name 경보 장치",
    "\"……\"",
    "@name 경보 장치",
    "\"저기요.\"",
    "@name 이하율",
    "\"왜요.\"",
    "@name 경보 장치",
    "\"측정을 진행해 주셔야 합니다.\"",
    "@name 이하율",
    "\"싫은데요.\"",
    "@name 경보 장치",
    "\"세계가 멸망합니다.\"",
    "@name 이하율",
    "\"그러시던지요??\"",
    "@name 경보 장치",
    ".....................",
    "\"...제작자님?\"",
    "@name 경보 장치",
    "\"플레이어가 2분째 아무것도 하지 않고 있습니다만?\"",
    "@name 경보 장치",
    "\"이거 어떻게 해야 합니까?\"",
    "@name 이하율",
    "\"ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅂㅅ\"",
    "@name 경보 장치",
    "\"망한 것 같습니다 씨발.\"",
};

fn startGame() void {
    state = .StoryIntro;
    show_credits = false;
    scene.setBackground("#181c24");
    global_textbox.load(&intro_script);
    requestRender();
}

fn startBonus() void {
    scene.setBackground("Images/thanks.png");
    playEndingScript(&bonus_script, "SPECIAL THANKS", "THANKS FOR PLAYING!", .{ 0.85, 0.15, 0.15, 1.0 }, false);
}

fn startMiniGame() void {
    state = .MiniGame;
    global_textbox.visible = false;
    game_running = false;
    game_elapsed = 0;
    idle_time = 0;
    scene.setBackground("Images/game.png");
    requestRender();
}

fn playEndingScript(script: []const []const u8, title: []const u8, subtitle: []const u8, col: [4]f32, flash: bool) void {
    current_ending_title = title;
    current_ending_subtitle = subtitle;
    ending_color = col;
    state = .EndingDialog;
    global_textbox.load(script);
    if (flash) {
        white_flash_alpha = 1.0;
    }
    requestRender();
}

var gpa_allocator: std.mem.Allocator = undefined;

var notbad_line1_buf: [128]u8 = undefined;
var notbad_sub_buf: [64]u8 = undefined;
var notbad_script_storage: [notbad_end_script.len][]const u8 = undefined;
var bad_line1_buf: [128]u8 = undefined;
var bad_script_storage: [bad_end_script.len][]const u8 = undefined;

fn finishMiniGame() void {
    game_running = false;
    measured_time = @round(game_elapsed * 100.0) / 100.0;
    const diff = @abs(measured_time - 10.00);

    if (diff == 0.0) {
        markEndingCleared(gpa_allocator, "true");
        if (success_sound) |s| s.play();
        scene.setBackground("Images/btnpress.png");
        playEndingScript(&true_end_script, "엔딩 2 — 세계구원", "TRUE END", .{ 0.1, 0.58, 0.25, 1.0 }, false);
    } else if (diff <= 1.00) {
        markEndingCleared(gpa_allocator, "notbad");
        if (not_bad_sound) |s| s.play();
        scene.setBackground("Images/btnpress.png");

        @memcpy(&notbad_script_storage, &notbad_end_script);
        notbad_script_storage[1] = std.fmt.bufPrint(&notbad_line1_buf, "\"측정 결과 {d:.2}초. 허용 오차를 초과하지 않았습니다.\"", .{measured_time}) catch notbad_end_script[1];
        const sub = std.fmt.bufPrint(&notbad_sub_buf, "측정 기록: {d:.2}초", .{measured_time}) catch "ENDING 2 — NOT BAD";
        playEndingScript(&notbad_script_storage, "ENDING 2 — NOT BAD", sub, .{ 0.12, 0.42, 0.78, 1.0 }, false);
    } else {
        markEndingCleared(gpa_allocator, "bad");
        scene.setBackground("Images/btnpress.png");

        @memcpy(&bad_script_storage, &bad_end_script);
        bad_script_storage[1] = std.fmt.bufPrint(&bad_line1_buf, "\"측정 실패 (기록: {d:.2}초). 핵폭탄을 발사합니다.\"", .{measured_time}) catch bad_end_script[1];
        playEndingScript(&bad_script_storage, "엔딩 1 — 세계멸망 (BAD)", "GAME OVER", .{ 1.0, 0.25, 0.25, 1.0 }, false);
    }
}

fn triggerIdleEnding() void {
    markEndingCleared(gpa_allocator, "idle");
    game_running = false;
    idle_time = 0;
    measured_time = 0;
    scene.setBackground("Images/hidden.png");
    playEndingScript(&idle_end_script, "엔딩 3 — 제작자 책임", "플레이어 부재", .{ 0.78, 0.36, 0.05, 1.0 }, false);
}

fn finishEndingDialog() void {
    if (std.mem.eql(u8, current_ending_subtitle, "GAME OVER")) {
        state = .GameOver;
        scene.setBackground("Images/bad.png");
        white_flash_alpha = 1.0;
        if (nes_explosion_sound) |s| s.play();
    } else {
        if (std.mem.eql(u8, current_ending_subtitle, "TRUE END")) {
            scene.setBackground("Images/good.png");
        } else if (std.mem.indexOf(u8, current_ending_title, "NOT BAD") != null) {
            scene.setBackground("Images/notbad.png");
        } else if (std.mem.eql(u8, current_ending_subtitle, "THANKS FOR PLAYING!")) {
            scene.setBackground("Images/thanks.png");
        } else if (std.mem.eql(u8, current_ending_subtitle, "플레이어 부재")) {
            scene.setBackground("Images/hidden.png");
        }
        state = .Result;
    }
    global_textbox.visible = false;
    requestRender();
}

fn onTextBoxComplete() void {
    if (state == .StoryIntro) {
        startMiniGame();
    } else if (state == .EndingDialog) {
        finishEndingDialog();
    }
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (action != c.GLFW_PRESS) return;

    if (key == c.GLFW_KEY_F11 or ((key == c.GLFW_KEY_ENTER or key == c.GLFW_KEY_KP_ENTER) and (mods & c.GLFW_MOD_ALT) != 0)) {
        setBorderless(window.?, !is_borderless);
        return;
    }

    var scale: i32 = 0;
    if (key == c.GLFW_KEY_F1) scale = 1;
    if (key == c.GLFW_KEY_F2) scale = 2;
    if (key == c.GLFW_KEY_F3) scale = 3;
    if (key == c.GLFW_KEY_F4) scale = 4;
    if (key == c.GLFW_KEY_F5) scale = 5;

    if (scale > 0) {
        const w = VirtualWidth * scale;
        const h = VirtualHeight * scale;
        if (c.glfwGetPrimaryMonitor()) |monitor| {
            var mx: c_int = 0;
            var my: c_int = 0;
            var mw: c_int = 0;
            var mh: c_int = 0;
            c.glfwGetMonitorWorkarea(monitor, &mx, &my, &mw, &mh);
            if (mw == 0 or mh == 0) {
                if (c.glfwGetVideoMode(monitor)) |vm| {
                    mw = vm.*.width;
                    mh = vm.*.height;
                }
            }
            var fl: c_int = 0;
            var ft: c_int = 0;
            var fr: c_int = 0;
            var fb: c_int = 0;
            c.glfwGetWindowFrameSize(window.?, &fl, &ft, &fr, &fb);
            if (w + fl + fr > mw or h + ft + fb > mh) {
                return;
            }
        }
        setBorderless(window.?, false);
        c.glfwSetWindowSize(window, w, h);
        requestRender();
        return;
    }

    if (key == c.GLFW_KEY_9 or key == c.GLFW_KEY_KP_9) {
        mute_mode = if (mute_mode == .Music) .None else .Music;
        applyMute();
        requestRender();
        return;
    }
    if (key == c.GLFW_KEY_0 or key == c.GLFW_KEY_KP_0) {
        mute_mode = if (mute_mode == .Master) .None else .Master;
        applyMute();
        requestRender();
        return;
    }

    switch (state) {
        .Title => {
            const num_items: usize = if (isBonusUnlocked()) 4 else 3;
            if (show_credits) {
                if (key == c.GLFW_KEY_SPACE or key == c.GLFW_KEY_ENTER or key == c.GLFW_KEY_ESCAPE) {
                    show_credits = false;
                    scene.setBackground("Images/main.png");
                    requestRender();
                }
                return;
            }

            if (key == c.GLFW_KEY_UP or key == c.GLFW_KEY_W) {
                selected_menu = (selected_menu + num_items - 1) % num_items;
                requestRender();
            } else if (key == c.GLFW_KEY_DOWN or key == c.GLFW_KEY_S) {
                selected_menu = (selected_menu + 1) % num_items;
                requestRender();
            } else if (key == c.GLFW_KEY_ENTER or key == c.GLFW_KEY_SPACE) {
                if (selected_menu == 0) {
                    startGame();
                } else if (selected_menu == 1) {
                    show_credits = true;
                    scene.setBackground("#FFFFFF");
                    requestRender();
                } else if (selected_menu == 2) {
                    c.glfwSetWindowShouldClose(window, c.GLFW_TRUE);
                } else if (selected_menu == 3 and num_items > 3) {
                    startBonus();
                }
            }
        },
        .StoryIntro, .EndingDialog => {
            if (key == c.GLFW_KEY_SPACE or key == c.GLFW_KEY_ENTER) {
                global_textbox.advance();
                requestRender();
            } else if (key == c.GLFW_KEY_ESCAPE or key == c.GLFW_KEY_TAB) {
                if (state == .StoryIntro) {
                    startMiniGame();
                } else if (state == .EndingDialog) {
                    finishEndingDialog();
                }
            }
        },
        .MiniGame => {
            if (key == c.GLFW_KEY_SPACE or key == c.GLFW_KEY_ENTER) {
                if (!game_running) {
                    game_running = true;
                    game_elapsed = 0;
                    idle_time = 0;
                    requestRender();
                } else {
                    finishMiniGame();
                }
            }
        },
        .GameOver, .Result => {
            if (key == c.GLFW_KEY_SPACE or key == c.GLFW_KEY_ENTER or key == c.GLFW_KEY_ESCAPE) {
                state = .Title;
                white_flash_alpha = 0;
                scene.setBackground("Images/main.png");
                requestRender();
            }
        },
    }
}

fn mouseButtonCallback(_: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (button == c.GLFW_MOUSE_BUTTON_LEFT and action == c.GLFW_PRESS) {
        if (state == .Title and show_credits) {
            show_credits = false;
            scene.setBackground("Images/main.png");
            requestRender();
        }
    }
}

fn framebufferResizeCallback(_: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
    global_engine.framebuffer_resized = true;
    requestRender();
}

pub fn main() !void {
    gpa_allocator = std.heap.c_allocator;

    loadClearedEndings(gpa_allocator);

    if (c.glfwInit() == 0) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);

    const window = c.glfwCreateWindow(WindowWidth, WindowHeight, "dead10sec", null, null) orelse return error.WindowCreateFailed;
    defer c.glfwDestroyWindow(window);
    global_window = window;

    _ = c.glfwSetKeyCallback(window, keyCallback);
    _ = c.glfwSetMouseButtonCallback(window, mouseButtonCallback);
    _ = c.glfwSetFramebufferSizeCallback(window, framebufferResizeCallback);

    audio.init();
    defer audio.deinit();

    hayul_sound = audio.createDialogueSound(gpa_allocator, 430.0, 1.0, 0.26);
    robot_sound = audio.createRobotSound(gpa_allocator, 180.0, 0.045, 0.24);
    success_sound = audio.createSuccessJingle(gpa_allocator, 0.35);
    nes_explosion_sound = audio.createNesExplosion(gpa_allocator, 0.85, 0.45);
    not_bad_sound = audio.createNotBadJingle(gpa_allocator, 0.35);

    bgm_sound = audio.createSoundFromMp3Memory(assets.bgm_call_to_adventure);
    if (bgm_sound) |s| {
        s.setVolume(bgm_base_volume);
        s.setLooping(true);
        s.play();
    }

    const engine = try Engine.init(gpa_allocator, window, VirtualWidth, VirtualHeight);
    global_engine = engine;

    renderer2d.init(gpa_allocator);

    const font14 = try Font.init(gpa_allocator, assets.font_galmuri14, 18);
    const fontBold = try Font.init(gpa_allocator, assets.font_galmuri11_bold, 14);
    const fontTitle = try Font.init(gpa_allocator, assets.font_galmuri11_bold, 28);

    const game_chars = @embedFile("assets/game_chars.txt");
    if (std.unicode.Utf8View.init(game_chars)) |view| {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            font14.addChar(cp, false);
            font14.addChar(cp, true);
            fontBold.addChar(cp, false);
            fontTitle.addChar(cp, false);
        }
    } else |_| {}

    try scene.init(gpa_allocator, @floatFromInt(VirtualWidth), @floatFromInt(VirtualHeight), texture_mod.white_tex_id);
    scene.preloadAll();
    scene.setBackground("Images/main.png");

    const box_x: f32 = 2;
    const box_w: f32 = @as(f32, @floatFromInt(VirtualWidth)) - 4;
    const box_h: f32 = 40;
    const box_y: f32 = @as(f32, @floatFromInt(VirtualHeight)) - 2 - box_h;

    var textbox = TextBox.init(gpa_allocator, font14, box_x + 10, box_y, box_w - 20, box_h, .{ 1, 1, 1, 1 });
    textbox.hayul_sound = hayul_sound;
    textbox.robot_sound = robot_sound;
    textbox.on_complete = onTextBoxComplete;
    global_textbox = &textbox;

    const box_bg_col = types.fromSrgb(0x22, 0x22, 0x22, 1.0);
    const box_bg_sprite = Sprite{
        .pos = .{ box_x, box_y },
        .size = .{ box_w, box_h },
        .layer = 5,
        .texture_id = texture_mod.white_tex_id,
        .color = box_bg_col,
        .visible = true,
    };

    const bt: f32 = 2.0;
    const border_sprites = [_]Sprite{
        .{ .pos = .{ box_x, box_y }, .size = .{ box_w, bt }, .layer = 6, .texture_id = texture_mod.white_tex_id, .color = .{ 1, 1, 1, 1 }, .visible = true },
        .{ .pos = .{ box_x, box_y + box_h - bt }, .size = .{ box_w, bt }, .layer = 6, .texture_id = texture_mod.white_tex_id, .color = .{ 1, 1, 1, 1 }, .visible = true },
        .{ .pos = .{ box_x, box_y }, .size = .{ bt, box_h }, .layer = 6, .texture_id = texture_mod.white_tex_id, .color = .{ 1, 1, 1, 1 }, .visible = true },
        .{ .pos = .{ box_x + box_w - bt, box_y }, .size = .{ bt, box_h }, .layer = 6, .texture_id = texture_mod.white_tex_id, .color = .{ 1, 1, 1, 1 }, .visible = true },
    };

    const arrow_pattern = [_][]const u8{
        "########",
        "########",
        ".######.",
        ".######.",
        "..####..",
    };
    const arrow_w = arrow_pattern[0].len;
    const arrow_h = arrow_pattern.len;
    var arrow_pixels: [arrow_w * arrow_h * 4]u8 = undefined;
    for (arrow_pattern, 0..) |row, ay| {
        for (row, 0..) |ch, ax| {
            const o = (ay * arrow_w + ax) * 4;
            if (ch == '#') {
                arrow_pixels[o + 0] = 255;
                arrow_pixels[o + 1] = 255;
                arrow_pixels[o + 2] = 255;
                arrow_pixels[o + 3] = 255;
            } else {
                arrow_pixels[o + 0] = 0;
                arrow_pixels[o + 1] = 0;
                arrow_pixels[o + 2] = 0;
                arrow_pixels[o + 3] = 0;
            }
        }
    }
    const arrow_tex = try texture_mod.loadRaw(&arrow_pixels, @intCast(arrow_w), @intCast(arrow_h));

    const music_icon_tex = scene.getOrLoadTexture("Images/iconmusic.png") orelse texture_mod.white_tex_id;
    const master_icon_tex = scene.getOrLoadTexture("Images/iconmaster.png") orelse texture_mod.white_tex_id;
    const x_icon_tex = scene.getOrLoadTexture("Images/iconx.png") orelse texture_mod.white_tex_id;

    // Initial draw to present first swapchain frame immediately on launch
    {
        renderer2d.frame_list.clearRetainingCapacity();
        is_dirty = false;
        const prefix_w = renderer2d.measureText(fontTitle, "10초 못 맞추면 ", 1.0);
        renderer2d.drawText(fontTitle, "10초 못 맞추면 ", .{ 40, 40 }, .{ 0.1, 0.1, 0.1, 1.0 }, 1.0, false);
        renderer2d.drawText(fontTitle, "세계멸망", .{ 40 + prefix_w, 40 }, .{ 0.85, 0.15, 0.15, 1.0 }, 1.0, false);
        renderer2d.drawText(fontBold, "10 SECONDS TO DOOM", .{ 42, 75 }, .{ 0.35, 0.35, 0.35, 1.0 }, 1.0, false);
        const menu_x: f32 = 460;
        const menu_y: f32 = 160;
        const init_items_3 = [_][]const u8{ "게임 시작", "크레딧", "종료" };
        const init_items_4 = [_][]const u8{ "게임 시작", "크레딧", "종료", "???" };
        const init_items = if (isBonusUnlocked()) init_items_4[0..] else init_items_3[0..];
        for (init_items, 0..) |item, i| {
            const is_sel = i == selected_menu;
            const prefix = if (is_sel) "> " else "  ";
            const col = if (is_sel) [4]f32{ 0.85, 0.15, 0.15, 1.0 } else [4]f32{ 0.2, 0.2, 0.2, 1.0 };
            var buf: [64]u8 = undefined;
            const menu_text = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, item }) catch item;
            renderer2d.drawText(fontBold, menu_text, .{ menu_x, menu_y + @as(f32, @floatFromInt(i)) * 32.0 }, col, 1.0, false);
        }
        renderer2d.drawText(font14, "↑/↓: 이동   Space: 선택", .{ menu_x - 20, 290 }, .{ 0.45, 0.45, 0.45, 1.0 }, 1.0, false);
        renderer2d.addFrame(.{ .pos = .{ 560, 12 }, .size = .{ 31, 32 }, .layer = 5, .texture_id = music_icon_tex });
        renderer2d.addFrame(.{ .pos = .{ 598, 12 }, .size = .{ 31, 32 }, .layer = 5, .texture_id = master_icon_tex });
        renderer2d.drawText(font14, "9", .{ 572, 60 }, .{ 0.4, 0.4, 0.4, 1.0 }, 1.0, false);
        renderer2d.drawText(font14, "0", .{ 610, 60 }, .{ 0.4, 0.4, 0.4, 1.0 }, 1.0, false);
        engine.drawFrame();
    }

    var last_time: f64 = c.glfwGetTime();

    while (c.glfwWindowShouldClose(window) == 0) {
        c.glfwPollEvents();

        const now_time: f64 = c.glfwGetTime();
        var dt: f32 = @floatCast(now_time - last_time);
        last_time = now_time;
        if (dt > 0.1) dt = 0.1;

        if (state == .StoryIntro or state == .EndingDialog) {
            textbox.update(dt);
            requestRender();
        } else if (state == .MiniGame) {
            idle_time += dt;
            if (game_running) {
                game_elapsed += dt;
            }
            if (idle_time >= 120.0) {
                triggerIdleEnding();
            }
            requestRender();
        }

        if (white_flash_alpha > 0.0) {
            white_flash_alpha = @max(0.0, white_flash_alpha - dt * 0.4);
            requestRender();
        }

        if (bgm_sound) |bgm| {
            const is_dialogue = (state == .StoryIntro or state == .EndingDialog) and textbox.visible;
            const target_vol: f32 = if (mute_mode != .None) 0.0 else (if (is_dialogue) bgm_dialogue_volume else bgm_base_volume);
            if (@abs(current_bgm_vol - target_vol) > 0.001) {
                const diff = target_vol - current_bgm_vol;
                current_bgm_vol += std.math.sign(diff) * @min(@abs(diff), dt * 0.5);
                bgm.setVolume(current_bgm_vol);
            }
        }

        if (is_dirty) {
            is_dirty = false;
            renderer2d.frame_list.clearRetainingCapacity();

            const cur_time: f32 = @floatCast(now_time);

            if (state == .Title) {
                if (show_credits) {
                    renderer2d.drawText(fontBold, "[ 크레딧 ]", .{ 25, 25 }, .{ 0.1, 0.1, 0.1, 1.0 }, 1.0, false);
                    const credits_body =
                        \\Code+Arts : Kkitut
                        \\Font : Galmuri
                        \\
                        \\[ BGM ]
                        \\"Call to Adventure" Kevin MacLeod (incompetech.com)
                        \\Licensed under Creative Commons: By Attribution 4.0 License
                        \\http://creativecommons.org/licenses/by/4.0/
                    ;
                    renderer2d.drawText(font14, credits_body, .{ 25, 55 }, .{ 0.2, 0.2, 0.2, 1.0 }, 1.0, false);
                } else {
                    const prefix_w = renderer2d.measureText(fontTitle, "10초 못 맞추면 ", 1.0);
                    renderer2d.drawText(fontTitle, "10초 못 맞추면 ", .{ 40, 40 }, .{ 0.1, 0.1, 0.1, 1.0 }, 1.0, false);
                    renderer2d.drawText(fontTitle, "세계멸망", .{ 40 + prefix_w, 40 }, .{ 0.85, 0.15, 0.15, 1.0 }, 1.0, false);
                    renderer2d.drawText(fontBold, "10 SECONDS TO DOOM", .{ 42, 75 }, .{ 0.35, 0.35, 0.35, 1.0 }, 1.0, false);

                    const menu_x: f32 = 460;
                    const menu_y: f32 = 160;
                    const items_3 = [_][]const u8{ "게임 시작", "크레딧", "종료" };
                    const items_4 = [_][]const u8{ "게임 시작", "크레딧", "종료", "???" };
                    const items = if (isBonusUnlocked()) items_4[0..] else items_3[0..];

                    for (items, 0..) |item, i| {
                        const is_sel = i == selected_menu;
                        const prefix = if (is_sel) "> " else "  ";
                        const col = if (is_sel) [4]f32{ 0.85, 0.15, 0.15, 1.0 } else [4]f32{ 0.2, 0.2, 0.2, 1.0 };
                        var buf: [64]u8 = undefined;
                        const menu_text = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, item }) catch item;
                        renderer2d.drawText(fontBold, menu_text, .{ menu_x, menu_y + @as(f32, @floatFromInt(i)) * 32.0 }, col, 1.0, false);
                    }
                    renderer2d.drawText(font14, "↑/↓: 이동   Space: 선택", .{ menu_x - 20, 290 }, .{ 0.45, 0.45, 0.45, 1.0 }, 1.0, false);
                }

                if (!show_credits) {
                    renderer2d.addFrame(.{ .pos = .{ 560, 12 }, .size = .{ 31, 32 }, .layer = 5, .texture_id = music_icon_tex });
                    renderer2d.addFrame(.{ .pos = .{ 598, 12 }, .size = .{ 31, 32 }, .layer = 5, .texture_id = master_icon_tex });
                    if (mute_mode == .Music) {
                        renderer2d.addFrame(.{ .pos = .{ 560, 12 }, .size = .{ 31, 32 }, .layer = 6, .texture_id = x_icon_tex, .color = .{ 0.85, 0.15, 0.15, 1.0 } });
                    } else if (mute_mode == .Master) {
                        renderer2d.addFrame(.{ .pos = .{ 598, 12 }, .size = .{ 31, 32 }, .layer = 6, .texture_id = x_icon_tex, .color = .{ 0.85, 0.15, 0.15, 1.0 } });
                    }
                    renderer2d.drawText(font14, "9", .{ 572, 60 }, .{ 0.4, 0.4, 0.4, 1.0 }, 1.0, false);
                    renderer2d.drawText(font14, "0", .{ 610, 60 }, .{ 0.4, 0.4, 0.4, 1.0 }, 1.0, false);
                }
            } else if (state == .StoryIntro or state == .EndingDialog) {
                const hint = if (state == .StoryIntro) "[ESC/TAB]: 도입 스킵" else "[ESC/TAB]: 스킵";
                renderer2d.drawText(font14, hint, .{ 10, 24 }, .{ 0.5, 0.5, 0.5, 0.8 }, 1.0, false);

                if (textbox.visible) {
                    renderer2d.addFrame(box_bg_sprite);
                    for (border_sprites) |bs| renderer2d.addFrame(bs);
                    textbox.draw();
                    if (textbox.blinkOn()) {
                        renderer2d.addFrame(.{
                            .pos = .{ box_x + box_w - 14, box_y + box_h - 11 },
                            .size = .{ @floatFromInt(arrow_w), @floatFromInt(arrow_h) },
                            .layer = 7,
                            .texture_id = arrow_tex,
                            .color = .{ 1, 1, 1, 1 },
                        });
                    }
                }
            } else if (state == .MiniGame) {
                const prompt_top = "10초를 정확히 감각으로 맞추십시오!";
                const pt_w = renderer2d.measureText(fontBold, prompt_top, 1.0);
                renderer2d.drawTextShake(fontBold, prompt_top, .{ @floor((@as(f32, @floatFromInt(VirtualWidth)) - pt_w) / 2.0), 25 }, .{ 0.85, 0.1, 0.1, 1.0 }, cur_time, 1.2, 1.0);

                if (!game_running) {
                    const prompt_bottom = "[ 스페이스바 ] 눌러서 타이머 가동";
                    const pb_w = renderer2d.measureText(fontBold, prompt_bottom, 1.0);
                    renderer2d.drawTextWave(fontBold, prompt_bottom, .{ @floor((@as(f32, @floatFromInt(VirtualWidth)) - pb_w) / 2.0), 305 }, .{ 0.1, 0.1, 0.1, 1.0 }, cur_time, 2.5, 6.0, 1.0);
                } else {
                    const running_status = "[ 타이머 작동 중... ]";
                    const running_hint = "10초라고 생각하는 순간 [스페이스바] 정지!";
                    const rs_w = renderer2d.measureText(fontBold, running_status, 1.0);
                    const rh_w = renderer2d.measureText(fontBold, running_hint, 1.0);
                    renderer2d.drawText(fontBold, running_status, .{ @floor((@as(f32, @floatFromInt(VirtualWidth)) - rs_w) / 2.0), 275 }, .{ 0.85, 0.2, 0.1, 1.0 }, 1.0, false);
                    renderer2d.drawTextWave(fontBold, running_hint, .{ @floor((@as(f32, @floatFromInt(VirtualWidth)) - rh_w) / 2.0), 305 }, .{ 0.1, 0.1, 0.1, 1.0 }, cur_time, 2.5, 6.0, 1.0);
                }
            } else if (state == .GameOver) {
                const left_pad: f32 = 36.0;
                const outline_col = [4]f32{ 1, 1, 1, 1 };
                renderer2d.drawTextOutlined(fontTitle, "GAME OVER", .{ left_pad, 60 }, .{ 0.9, 0.15, 0.15, 1.0 }, outline_col, 2, 1.0, false);
                renderer2d.drawTextOutlined(fontBold, "측정 실패. 전 세계의 핵폭탄이 동시 기폭되었습니다.", .{ left_pad, 110 }, .{ 0, 0, 0, 1.0 }, outline_col, 2, 1.0, false);

                var rec_buf: [64]u8 = undefined;
                const rec_str = std.fmt.bufPrint(&rec_buf, "측정 기록: {d:.2}초", .{measured_time}) catch "측정 기록";
                renderer2d.drawTextOutlined(fontBold, rec_str, .{ left_pad, 140 }, .{ 0, 0, 0, 1.0 }, outline_col, 2, 1.0, false);
                renderer2d.drawTextOutlined(fontBold, "[ 스페이스바 ] 타이틀로", .{ left_pad, 305 }, .{ 0, 0, 0, 1.0 }, outline_col, 2, 1.0, false);
            } else if (state == .Result) {
                const left_pad: f32 = 36.0;
                const outline_col = [4]f32{ 1, 1, 1, 1 };

                if (std.mem.eql(u8, current_ending_subtitle, "THANKS FOR PLAYING!")) {
                    renderer2d.drawTextOutlined(fontBold, current_ending_title, .{ left_pad, 45 }, ending_color, outline_col, 2, 1.0, false);
                    renderer2d.drawTextOutlined(fontTitle, current_ending_subtitle, .{ left_pad, 75 }, ending_color, outline_col, 2, 1.0, false);
                    renderer2d.drawTextOutlined(fontBold, "모든 엔딩 클리어 달성!", .{ left_pad, 130 }, .{ 0.15, 0.15, 0.15, 1.0 }, outline_col, 2, 1.0, false);
                    renderer2d.drawTextOutlined(fontBold, "[ 스페이스바 ] 타이틀로", .{ left_pad, 305 }, .{ 0.2, 0.2, 0.2, 1.0 }, outline_col, 2, 1.0, false);
                } else {
                    const diff = @abs(measured_time - 10.00);
                    renderer2d.drawTextOutlined(fontBold, current_ending_title, .{ left_pad, 45 }, ending_color, outline_col, 2, 1.0, false);
                    renderer2d.drawTextOutlined(fontTitle, current_ending_subtitle, .{ left_pad, 75 }, ending_color, outline_col, 2, 1.0, false);

                    if (std.mem.eql(u8, current_ending_subtitle, "플레이어 부재")) {
                        renderer2d.drawTextOutlined(fontBold, "행동 없음", .{ left_pad, 135 }, .{ 0.15, 0.15, 0.15, 1.0 }, outline_col, 2, 1.0, false);
                    } else if (measured_time > 0) {
                        var err_buf: [64]u8 = undefined;
                        const err_str = std.fmt.bufPrint(&err_buf, "오차 : {d:.2}초", .{diff}) catch "오차";
                        renderer2d.drawTextOutlined(fontBold, err_str, .{ left_pad, 135 }, .{ 0.15, 0.15, 0.15, 1.0 }, outline_col, 2, 1.0, false);
                    }
                    renderer2d.drawTextOutlined(fontBold, "[ 스페이스바 ] 타이틀로", .{ left_pad, 305 }, .{ 0.2, 0.2, 0.2, 1.0 }, outline_col, 2, 1.0, false);
                }
            }

            if (white_flash_alpha > 0.01) {
                renderer2d.addFrame(.{
                    .pos = .{ 0, 0 },
                    .size = .{ @floatFromInt(VirtualWidth), @floatFromInt(VirtualHeight) },
                    .layer = 200,
                    .texture_id = texture_mod.white_tex_id,
                    .color = .{ 1, 1, 1, white_flash_alpha },
                });
            }

            engine.drawFrame();
        }

        c.glfwWaitEventsTimeout(0.004);
    }
}
