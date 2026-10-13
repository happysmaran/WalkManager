# WalkManager

WalkManager is a simple GUI utility that converts a local music library to MP3 and syncs it onto USB mass-storage MP3 players (Walkman-style devices, Sansa Clip, plain flash drives, any other cursed mp3 players you find). It shows each connected device with a capacity bar, lets you pick where on the device music should go, and only transfers songs that are not already there.

There are two native versions with the same behavior and almost same UI:

| Platform | Folder | Stack |
| --- | --- | --- |
| macOS | [`WalkManager/`](WalkManager) + [`WalkManager.xcodeproj`](WalkManager.xcodeproj) | Swift, SwiftUI, DiskArbitration, AVFoundation |
| Windows | [`WalkManager_Win/`](WalkManager_Win) | Rust, egui/eframe, Win32 (`windows-sys`), rayon |

## Features

- **Device sidebar.** Lists removable USB volumes and updates as drives are plugged in or removed. Players are recognized on a best-effort basis from vendor, model, and volume name, since they present themselves as generic mass storage.
- **Storage bar.** Used, free, and total capacity for the selected device, refreshed after every transfer or deletion.
- **Destination picker.** Detects top-level folders named `music`, `mp3`, `songs`, or `audio` (plus `musik` on Windows) and offers them alongside the device root, because players differ in where they expect files.
- **Format conversion.** Accepts `wav`, `flac`, `m4a`, `aac`, `aiff`, `ogg`, `alac`, `mp3`, and `wma`, and writes MP3 at 128, 192, 256, or 320 kbps with ID3 tags carried over from the source.
- **Incremental sync.** Songs already on the device (matched by file name) are left untouched. Existing MP3s at or near the target bitrate are copied instead of re-encoded.
- **Overwrite mode.** Hold **⌥ Option** (macOS) or **Ctrl** (Windows) while clicking the transfer button to delete and re-write every song that is already on the device.
- **Song list.** Browse, with duration and size, the MP3s on the device and delete individual tracks after a confirmation prompt.
- **Per-device memory.** Bitrate, destination folder, and source library folder are remembered for each device.

## Requirements

- [FFmpeg](https://ffmpeg.org) for conversion backend (and duration display on Windows, which uses `ffprobe` from FFmpeg)
  - **macOS:** install with Homebrew (`brew install ffmpeg`). WalkManager looks in `/opt/homebrew/bin` and `/usr/local/bin`.
  - **Windows:** install with chocolatey (`choco install ffmpeg`), winget (`winget install ffmpeg`) or scoop (`scoop install ffmpeg`), or put `ffmpeg.exe` and `ffprobe.exe` on your `PATH`, or next to `walk-manager-win.exe`.
- **macOS build:** Xcode with a deployment target of macOS 14.6 or later.
- **Windows build:** a Rust toolchain that supports the 2024 edition (Rust 1.85 or later).

## Building and running

### macOS

1. Open `WalkManager.xcodeproj` in Xcode.
2. Select the **WalkManager** scheme and press **Run**.

Keep in mind the app runs without the App Sandbox so it can read and write mounted volumes and launch FFmpeg.

### Windows

```powershell
cd WalkManager_Win
cargo run --release
```

The optimized binary is written to `WalkManager_Win\target\release\walk-manager-win.exe`.

## Usage

1. Plug in your player or USB drive and select it in the sidebar.
2. Under **Sync Settings**, choose your **Music Folder** (the local library to read from, scanned recursively).
3. Pick the **Destination on Device** and the **MP3 Export Quality**.
4. Click **Convert & Transfer**. Progress and counts of transferred and skipped songs are shown while it runs.

To refresh the device's contents from scratch, hold ⌥ Option / Ctrl as you click and the button changes to **Overwrite & Transfer**.

## How it works

- **Device detection.** macOS registers DiskArbitration callbacks for disk appearance, removal, and description changes and filters mounted volumes to removable or ejectable ones. Windows enumerates logical drives with `GetLogicalDrives` and keeps those that `GetDriveTypeW` reports as removable.
- **Conversion.** A pool of workers (an `OperationQueue` on macOS, rayon on Windows) runs one FFmpeg process per file with `libmp3lame`, ID3v2.3 and ID3v1 tags, and metadata mapped from the source. An MP3 is re-encoded only when its estimated bitrate is more than 15 kbps above the target.
- **Settings storage.** Devices are keyed on what they report (vendor, model, and volume name on macOS; volume name and drive letter on Windows). Two identical drives with the same label share settings. macOS stores settings in `UserDefaults` and keeps the library folder as a security-scoped bookmark. Windows stores JSON at `%LOCALAPPDATA%\WalkManager\device_settings.json`.

## Project layout

```
WalkManager/
├── WalkManager/               # macOS app
│   ├── WalkManagerApp.swift   # app entry point
│   └── ContentView.swift      # UI, device model, DeviceManager, settings store, AudioConverter
├── WalkManager.xcodeproj/
└── WalkManager_Win/           # Windows app
    └── src/
        ├── main.rs            # window setup
        ├── app.rs             # egui UI and app state
        ├── device.rs          # removable drive enumeration and capacity
        ├── converter.rs       # FFmpeg conversion, track scanning
        └── settings.rs        # per-device settings persistence
```

## License

Released under the [MIT License](LICENSE).
