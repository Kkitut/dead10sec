# 10 SECONDS TO DOOM

A minimal timer game  
In-game dialogue and text are in Korean.  

## Controls

### Display and Audio
- F1 - F5: scale factor (1x to 5x, clamped to display bounds)
- F11 / Alt + Enter: borderless
- 9 - BGM mute
- 0 - master mute

### Gameplay
- Select - Space / Enter
- Move - Up / Down / W / S
- Skip - ESC / Tab

## Endings

The game features 4 endings...

## Building from Source

### Requirements
- Zig (0.16.0 or newer)
- Vulkan SDK / Driver and Headers
- GLFW 3

### Linux
```bash
# Run
zig build run

# Release build
zig build -Doptimize=ReleaseFast
```

### Windows (Cross-compilation)
```bash
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

## Licenses and Credits

- Source Code: [GNU General Public License v3.0 (GPL-3.0)](LICENSE.md)

### Asset Credits
- Artwork - Kkitut ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/))
- Font - Galmuri by Wonho Park ([OFL-1.1](https://openfontlicense.org/))
- BGM - *"Call to Adventure"* by Kevin MacLeod ([CC BY 4.0](http://creativecommons.org/licenses/by/4.0/))
  - Licensed under Creative Commons - By Attribution 4.0 License
  - Source - http://creativecommons.org/licenses/by/4.0/
