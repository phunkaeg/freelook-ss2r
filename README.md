# Freelook Mode
### for *System Shock 2: 25th Anniversary Remaster*

Free-aim like the original **System Shock (1994)**: press **F5** and move the crosshair independently of the camera. The view edge-pans when the reticle reaches the screen border.

Works with all guns, projectiles, melee (wrench included), muzzle flash, and object selection. **Resolution-independent** — the HUD overlay space is auto-calibrated at runtime (tested at 1920×1080 and 3440×1440 ultrawide).

📦 **[Download the latest release](https://github.com/phunkaeg/freelook-ss2r/releases/latest)**

---

## What's in the zip

| File | Purpose |
|---|---|
| `FreelookLoader.exe` | starts the game with the mod loaded |
| `Launch Freelook.bat` | double-click alternative to the loader |
| `FlatAim.dll` | the mod itself (loaded by the loader) |
| `flataim.ini` | tuning knobs (sensible defaults) |
| `FreelookSavePatcher.exe` | adds the mod to **existing** save games |
| `mods\flataim.kpf` | the in-game script package |

## Install

1. Copy `FreelookLoader.exe`, `Launch Freelook.bat`, `FlatAim.dll` and `flataim.ini` into the **game folder** (the folder containing `SystemShock2Remastered.exe`).
2. Copy `flataim.kpf` into the game's **`mods`** folder.
3. Start the game **one** of these ways:
   - double-click **`Launch Freelook.bat`** (or `FreelookLoader.exe`), or
   - Steam → SS2 Remastered → Properties → **Launch Options**:
     ```
     "C:\full\path\to\FreelookLoader.exe" %command%
     ```
     then launch from Steam normally, forever.
4. **Existing saves only:** run `FreelookSavePatcher.exe` once. It lists your saves **by name**, you pick which to patch (or `A` for all), and it **backs up** every save it touches (`*.pre-freelook.bak`, plus the patcher's own backup) before adding the mod. New games need no patching.

## Use

| | |
|---|---|
| **F5** | toggle Freelook on/off *(rebindable, see below)* |
| **Mouse** | moves the crosshair; the view edge-pans at the borders |
| **`flataim.ini`** | sensitivity, edge-pan feel, weapon pivot, melee placement — documented inline. Re-read every time you toggle Freelook on; no restart needed. |

## Rebinding the toggle

In `flataim.ini`, set `toggle_vk` to a Windows virtual-key code (hex). Default: `toggle_vk=0x74` (F5).

| Key | Code | | Key | Code |
|---|---|---|---|---|
| F1 … F12 | `0x70` … `0x7B` | | Tab | `0x09` |
| **F5 (default)** | `0x74` | | Caps Lock | `0x14` |
| Mouse middle | `0x04` | | Tilde `~` | `0xC0` |
| Mouse back (X1) | `0x05` | | Space | `0x20` |
| Mouse forward (X2) | `0x06` | | 0 … 9 | `0x30` … `0x39` |
| A … Z | `0x41` … `0x5A` | | e.g. V | `0x56` |

Full list: search "Windows virtual key codes" (`VK_*`). Left/right mouse buttons (`0x01`/`0x02`) are **not recommended** — they're the fire/use buttons. Changes take effect next launch (or next Freelook toggle if already running).

## Uninstall

Delete the five files from the game folder and `mods\flataim.kpf`. To un-patch a save, restore its `*.pre-freelook.bak` (rename back to the original name). Remove the Steam launch option if you set it.

## Troubleshooting

- **F5 does nothing** — check `flataim.log` in the game folder. `waiting for SS2FA Squirrel bridge` means `mods\flataim.kpf` isn't loading; for an existing save, run `FreelookSavePatcher.exe`.
- **Crosshair off-centre** — shouldn't happen (auto-calibration). Open an issue with `flataim.log` and your resolution.
- **Saves not found by the patcher** — it resolves your real Windows *Saved Games* folder (including relocated/OneDrive profiles); if yours still isn't found it will ask for the path.
- **Antivirus flags the loader/DLL** — false positive common to all injection-based game mods. The full source is this repository. VirusTotal: [LINK].

## Known issues

None blocking at release. Report issues **[here](https://github.com/phunkaeg/freelook-ss2r/issues)** — include `flataim.log`.

## Building from source

- `dll/` — `FlatAim.dll` (CMake, fetches MinHook)
- `loader/` — `FreelookLoader.exe` (CMake, no dependencies)
- `mod/` — zip the contents (`modinfo.json` + `sq_scripts/`) into `flataim.kpf`
- `tools/` — save patcher (`freelook_patch_saves.py`; package with PyInstaller `--onefile`)

## Credits

**Code & design:** FUNK
Built with [MinHook](https://github.com/TsudaKageyu/minhook) © Tsuda Kageyu (BSD-2-Clause).
Thanks to the **Nightdive Discord community** for the original request.

*Not affiliated with Nightdive Studios. Use at your own risk.*
