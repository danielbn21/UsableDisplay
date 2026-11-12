<p align="center">
  <img src="AppIcon-1024.png" alt="UsableDisplay icon" width="160">
</p>

<h1 align="center">UsableDisplay</h1>

<p align="center">
  A small macOS menu bar app that lets you use only the <em>working part</em> of a display with dead pixels, or make a big screen behave like a smaller one.
</p>

---

## What it does

Got a dead row of pixels along the edge of your OLED TV or monitor? UsableDisplay hides it behind a black border and makes macOS treat the rest of the screen as the whole desktop, so the menu bar, Dock and windows never go under the damaged area.

It can also emulate a **smaller screen** on a larger panel. For example, it can make a 48″ TV behave like a 24″ or 40″ monitor by changing a number.

It was built for an LG C1 48″ (3840×2160) on an M4 Mac mini running macOS 15 with a strip of 16 dead dead at the top. It should work with any display macOS can drive.

## How it works

macOS has no built-in underscan for HDMI displays, and a black bar drawn on top of the screen doesn't change the usable desktop area. UsableDisplay does this instead:

1. It creates a **virtual display** at the usable size (the panel size minus your borders).
2. It makes the virtual display your main display, so the menu bar, Dock and new windows land there.
3. It captures the virtual display with **ScreenCaptureKit**.
4. It shows that capture in a borderless, black, full-screen window on the physical display. The window is offset by your border sizes, so the black frame covers the dead pixels.

## Features

- Border size in physical pixels for each edge (top, bottom, left, right).
- Optional **screen size mode**: enter the diagonal you want (24″, 40″ and so on) and the image is scaled and centered.
- Aspect ratio lock with presets (panel, 16:9, 16:10, 4:3, 21:9) or a custom ratio.
- HiDPI (2×) or 1× virtual screen, and 30, 60 or 120 Hz refresh.
- Live summary of the resulting virtual resolution and position.
- Menu bar app with Enable/Disable, Re-apply and Launch at Login.
- Re-applies itself when the display disconnects and reconnects, for example after the TV is power-cycled.
- Settings are saved between launches. Nothing is hard-coded to one monitor.

## Requirements

- macOS 14 or later (developed and tested on macOS 15)
- Apple silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

## Build

```bash
git clone <this repo>
cd UsableDisplay
./build.sh
open UsableDisplay.app
```

`build.sh` compiles `main.swift` with `swiftc`, generates the app icon from `AppIcon-1024.png`, bundles `MenuIcon.png`, and ad-hoc signs the result. To keep the app, move `UsableDisplay.app` to `/Applications`.

## First run

1. Open the app. A monitor icon appears in the menu bar.
2. macOS asks for **Screen Recording** permission. Enable it under *System Settings → Privacy & Security → Screen & System Audio Recording*.
3. Choose **Re-apply** from the menu bar icon.
4. Open **Settings…**, enter your border sizes and press **Apply**.

Because the build is ad-hoc signed, macOS may ask for the permission again after you rebuild.

## Usage

| Setting | Meaning |
|---|---|
| **Display** | Which physical display to work on. |
| **Real panel diagonal** | Actual size of your screen in inches. Only used for the inch conversion. |
| **Mode: Border pixels** | The image fills the panel minus the borders you set. |
| **Mode: Screen size** | The image is scaled to look like a screen of the given diagonal and centered. Borders still reserve the dead area. |
| **Top / Bottom / Left / Right** | Pixels kept black on each edge of the physical panel. |
| **Keep aspect ratio** | Adds extra black on the other edges so the image keeps the chosen shape. |
| **HiDPI (2×)** | Sharper UI that looks half the pixel size. Turn it off for small emulated sizes, where a HiDPI UI looks very large. |
| **Refresh rate** | Refresh rate of the virtual screen. |

**Example (LG C1 48″, 16 px dead strip at the top):** set Top to 16 and leave the other sides at 0. With the aspect ratio locked to 16:9, this gives a 3810×2144 virtual screen.

## Known limitations

- **Private API.** The virtual display uses `CGVirtualDisplay`, an undocumented CoreGraphics interface (the same one used by tools like BetterDisplay and DeskPad). A future macOS update could break it.
- **Slight overhead.** Capturing and redrawing adds roughly a frame of latency and some GPU use. It's fine for desktop work but not ideal for fast games.
- **Cursor.** The physical display is placed diagonally off the virtual one, touching only at a corner, so the cursor rarely wanders onto the black overlay. It can still happen at the exact corner.
- **Other screens.** DRM-protected video may show as black in a capture, depending on the app.

## Troubleshooting

- **Nothing happens, or the screen stays black.** Check the Screen Recording permission, then choose **Re-apply**. To see the app's log, run `log stream --predicate 'eventMessage CONTAINS "UsableDisplay"'`.
- **Stuck overlay.** Choose **Quit** from the menu bar icon, or run `pkill UsableDisplay`.
- **Ghosting or double images on the TV.** Turn off motion processing on the TV (on LG OLED: TruMotion / Motion Eye Care and OLED Motion Pro), and use Game or PC mode.
- **Icon doesn't update after a rebuild.** Run `killall Finder` and `killall Dock`.
- **Interface looks too large.** Turn HiDPI off in Settings.

## Project layout

```
main.swift          App source (UI, virtual display, capture, overlay)
Bridging.h          Declarations for the private CGVirtualDisplay API
Info.plist          App bundle metadata (menu bar app, no Dock icon)
build.sh            Build script (compile, icons, sign)
AppIcon-1024.png    App icon source
MenuIcon.png        Menu bar template icon (@3x)
```

## Privacy

UsableDisplay never sends anything over the network. It captures only its own virtual display, and only to draw it on your physical display. Settings are stored locally in `UserDefaults`.

## Contributing

Issues and pull requests are welcome. Tested configurations (display model, Mac model, macOS version) are especially useful.

## License

Add your license here (for example MIT) and include a `LICENSE` file.
