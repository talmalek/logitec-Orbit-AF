# Logitech Orbit AF – Web Pan/Tilt Controller

Browser-based pan/tilt controller for the **Logitech QuickCam Orbit AF** (VID `046d`, PID `0994`), wrapped in a retro TV interface.

![Orbit AF Controller UI](screenshot.png)

The camera's motorized pan/tilt is driven by a Logitech-proprietary UVC Extension Unit (Unit ID `0x09`), which standard browser APIs don't expose. A single native macOS binary (`uvc_ctrl`) handles USB control transfers via IOKit — no Python, no pip, no sudo required.

## Features

- **Retro TV interface** — camera feed displayed inside a vintage TV with controls on the side panel
- **Standalone video viewer** — open `index.html` in Chrome to view any connected webcam, no server needed
- **Dynamic format detection** — automatically probes each camera for its actual supported resolutions and frame rates
- **Highest resolution by default** — opens camera at its maximum supported resolution
- **Multi-camera support** — switch between cameras from a dropdown (e.g., built-in + USB)
- **Pan/tilt motor control** — pan/tilt via on-screen D-pad, keyboard arrows, or speed slider
- **Camera image settings** — brightness, contrast, saturation, sharpness sliders (via USB)
- **Reset to defaults** — one-click factory reset for all image settings
- **Microphone capture** — automatically detects and captures audio from the camera's built-in microphone
- **Mute toggle** — mute/unmute mic with one click or the <kbd>M</kbd> key; stop capture with double-click
- **Live spectrum analyzer** — real-time frequency bar visualization overlaid on the video frame
- **Level meter** — compact audio level bar next to the mic button, always visible regardless of analyzer state
- **Spectrum toggle** — show/hide the video-frame equalizer without affecting the level meter
- **LED control** — on/off/blink/auto for the camera LED
- **Position editor** — press Ctrl+E to visually reposition UI elements on the TV
- **Zero dependencies** — single Objective-C file, compiled with system frameworks only

## Maintainers

| Name | GitHub |
|------|--------|
| Tal Malek | [@talmalek](https://github.com/talmalek) |

## Prerequisites

- **macOS** (uses IOKit + AVFoundation; no sudo needed)
- **Xcode Command Line Tools** — install with `xcode-select --install`
- **Google Chrome** (recommended for `getUserMedia` support)
- **Logitech QuickCam Orbit AF** plugged in via USB

## Quick Start

### Option A: Double-click (easiest)

1. **Open `index.html`** in Chrome → camera video works immediately at max resolution
2. **Double-click `start_ptz.command`** in Finder → compiles (if needed) and starts PTZ server
3. **Toggle PTZ on** in the web page → arrow controls and camera settings become active

### Option B: Terminal

```bash
# 1. Compile (one-time)
clang -o uvc_ctrl uvc_ctrl.m -framework IOKit -framework CoreFoundation \
      -framework AVFoundation -framework CoreMedia -fobjc-arc

# 2. Open index.html in Chrome → video works immediately

# 3. When you want PTZ control:
./uvc_ctrl
# Then toggle PTZ on in the web page
```

## How It Works

```
┌────────────────────────┐                  ┌─────────────────────┐
│  Chrome (index.html)   │  getUserMedia    │                     │
│                        │──> USB Video ──> │  Logitech Orbit AF  │
│  Retro TV Interface    │                  │  (046d:0994)        │
│  Video + Formats       │                  │                     │
│  (works standalone)    │  HTTP POST       │                     │
│                        │──> /api/ptz ──>  │  USB Control Pipe   │
│  PTZ D-Pad ────────────│──> /api/setting  │  Extension Unit 9   │
│  Settings Sliders ─────│──> /api/reset    │                     │
└────────────────────────┘                  └─────────────────────┘
          │
          │ localhost:9090 (only needed for pan/tilt)
          ▼
┌────────────────────────┐
│  ./uvc_ctrl             │
│  (Obj-C + IOKit)        │
│  Pan/tilt server + USB  │
└────────────────────────┘
```

- **Video & format selection** work by opening `index.html` in Chrome — no server needed.
- **Pan/tilt & camera settings** require `./uvc_ctrl` running — toggle PTZ on in the page to connect.

## Project Structure

```
logitec_Orbit_AF/
├── index.html            # Retro TV web UI (standalone camera viewer + PTZ controls)
├── tv-bg.png             # TV background image used by the UI
├── screenshot.png        # UI screenshot used in README
├── uvc_ctrl.m            # Native macOS binary source (Obj-C, IOKit, AVFoundation)
├── start_ptz.command     # Double-clickable launcher for PTZ server
├── README.md             # This file
└── 27495.1.0.pdf         # Logitech UVC protocol reference
```

## Controls

| Control | Action |
|---------|--------|
| Arrow buttons / keyboard arrows | Pan left/right, tilt up/down |
| Home button / <kbd>H</kbd> key | Reset pan/tilt to center |
| Speed slider | Adjust movement step size (1–10) |
| Format dropdown | Switch resolution and frame rate |
| PTZ toggle | Connect/disconnect to PTZ server |
| Settings button | Open camera settings drawer (brightness, contrast, etc.) |
| Default button | Reset all image settings to factory defaults |
| Mic button (single click) | Start microphone / toggle mute |
| Mic button (double-click) | Stop microphone capture entirely |
| <kbd>M</kbd> key | Toggle mic mute |
| ▩ button (next to level meter) | Show/hide spectrum analyzer on video frame |
| <kbd>Ctrl</kbd>+<kbd>E</kbd> | Open position editor to adjust UI element layout |

## API Endpoints

When the PTZ server is running (`./uvc_ctrl`), these endpoints are available at `http://localhost:9090`:

| Method | Path | Body | Description |
|--------|------|------|-------------|
| GET | `/` | – | Serves the HTML UI |
| GET | `/api/status` | – | Camera connection check |
| GET | `/api/formats` | – | List all cameras and their supported formats |
| GET | `/api/settings` | – | Get current image settings with min/max ranges |
| POST | `/api/ptz` | `{ "pan": int, "tilt": int }` | Relative pan/tilt move |
| POST | `/api/reset` | – | Reset pan/tilt to home position |
| POST | `/api/setting` | `{ "name": str, "value": int }` | Set a camera image setting |
| POST | `/api/settings/reset` | – | Reset all settings to factory defaults |
| POST | `/api/led` | `{ "mode": "off\|on\|blink\|auto" }` | Control camera LED |

## CLI Usage

The binary also works as a standalone CLI tool:

```bash
./uvc_ctrl                  # start PTZ server (default)
./uvc_ctrl pantilt 3 0      # pan right
./uvc_ctrl pantilt -3 0     # pan left
./uvc_ctrl pantilt 0 3      # tilt up
./uvc_ctrl pantilt 0 -3     # tilt down
./uvc_ctrl reset             # center position
./uvc_ctrl led on            # LED on
./uvc_ctrl led blink         # LED blink
./uvc_ctrl status            # check camera connection
./uvc_ctrl --help            # show all commands
```

## Audio & Spectrum Analyzer

The Logitech Orbit AF has a built-in microphone that macOS detects as a separate USB audio input ("Unknown USB Audio Device", 1 channel, 16 kHz). The web UI can capture and visualize it directly using the Web Audio API.

### Mic controls

| State | Button appearance | How to get there |
|-------|-------------------|-----------------|
| Off | Grey 🎤 | Initial state |
| Active | Green 🎤 | Single click |
| Muted | Red 🔇 | Click again (or press <kbd>M</kbd>) |
| Stopped | Grey 🎤 | Double-click while active |

- The page automatically tries to match the microphone to the currently selected camera (e.g. choosing the Orbit AF camera will prefer the USB audio input over the MacBook mic).
- The small **level meter** bar always shows audio level when the mic is active — it is unaffected by the spectrum toggle.

### Spectrum analyzer

A real-time frequency bar visualization is overlaid on the bottom portion of the video frame when the mic is active and unmuted:

- Bars are colour-coded green → amber → red by amplitude
- Use the **▩** button next to the level meter to show/hide the overlay without stopping the mic
- The level meter remains active even when the overlay is hidden

## Troubleshooting

### "Logitech Orbit AF not found"
- Verify the camera is plugged in: **System Information → USB**
- Confirm VID:PID is `046d:0994`
- Make sure no other application has exclusive USB access

### Permission denied / USB errors
- The binary does **not** need sudo on macOS
- Check **System Preferences → Privacy & Security → USB Accessories**

### Video works but PTZ doesn't
- Video uses a different path (OS → Chrome) than PTZ (`uvc_ctrl` → USB control pipe)
- Check the terminal for USB transfer errors
- Try resetting the camera: unplug, wait 5 seconds, plug back in

### Camera not listed in dropdown
- Grant Chrome camera permissions when prompted
- Try a different USB port or hub

### "Detecting formats…" is slow
- Format probing tests ~14 standard resolutions on first use, then caches results
- Subsequent visits to the same camera are instant

## Protocol Reference

Based on [mhorowitz/orbitctl](https://github.com/mhorowitz/orbitctl) and [filiptc/gorbit](https://github.com/filiptc/gorbit):

| Parameter | Value |
|-----------|-------|
| Logitech Motor Extension Unit ID | `0x09` |
| Pan/Tilt Relative Selector | `0x01` (4 bytes) |
| Pan/Tilt Reset Selector | `0x02` (1 byte: `0x03` = reset both) |
| LED Control Unit ID | `0x0A`, Selector `0x01` |
| Processing Unit ID | `0x02` (brightness, contrast, etc.) |
| bmRequestType (SET) | `0x21` |
| bRequest (SET_CUR / GET_CUR / GET_MIN / GET_MAX / GET_DEF) | `0x01` / `0x81` / `0x82` / `0x83` / `0x87` |

## License

MIT
