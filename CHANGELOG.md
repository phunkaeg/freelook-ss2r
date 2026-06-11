# Changelog

## v1.0.1 (unreleased)

### Fixed
- **Launch failures on some Steam setups** ("Injection failed (alloc/write)"). The loader
  now follows Steam's process relaunch (it polls for the real game process by name instead
  of trusting the process it started), and detects the Administrator/elevation-mismatch case
  with a clear message. It also writes `freelookloader.log` for diagnosis. Single-file swap —
  only `FreelookLoader.exe` changed.
- **`freelook_press_type=hold` and `edge_pan_press_type` were ignored** whenever the ini line
  had a trailing `; comment` (which the shipped ini does on every line). `GetPrivateProfileString`
  doesn't strip inline comments, so the value came back as e.g. `"hold     ; toggle or hold"` and
  the exact-match parse fell through to the default. String ini reads now strip inline comments
  and surrounding whitespace. Integer/float settings were never affected.

### Added
- **`weapon_view_rotate`** (ini, default `1`). Set to `0` to keep the weapon viewmodel in its
  neutral rest pose instead of rotating it toward the crosshair — aim and projectiles still
  track the crosshair, only the gun model stays put.
