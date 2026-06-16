# Changelog

## v1.0.2 — 2026-06-16

### Fixed
- **Some switches/keypads wouldn't frob from one side.** The free-aim selection's
  "is it in front of you?" test was too strict — a target your reticle was clearly on
  could be dropped when your head faced away from it. It now allows a small tolerance,
  so frobbing works the same from either side.
- **Melee (wrench) blocked ALL frobbing after using Freelook.** The melee viewmodel sits
  at screen-centre; after free-aim the engine's frob pick started landing on your own
  weapon mesh instead of the world behind it. Your own viewmodel is now excluded from the
  frob pick (in or out of Freelook), so the wrench frobs normally again.
- **Console/log spam + a related framerate hitch from the Squirrel->DLL bridge.** Each
  heartbeat and selection update echoed two console lines, churning the ~1024-line console
  ring and dragging FPS. The DLL now captures those high-frequency bridge writes silently.
- **FPS drag while the mod is loaded**: the selection scan classified every live object
  each tick (name/property/link reads) before checking geometry, and the Squirrel→DLL
  bridge republished an unchanged "no target" every 160 ms (two console echo lines per
  publish). Geometry gates now run first, family checks are cached per archetype, and
  the no-target publish fires once instead of forever.
- **Items un-frobbable in normal (non-Freelook) play after using Freelook**: the DLL
  forces the engine cursor + hover/frob globals while Freelook is active but never
  restored them on exit. Deactivation now re-centers the cursor and clears the forced
  hover state. (Reported: keypad not frobbable outside free-aim.)
- **Reload animations now play on the Freelook weapon** (`weapon anim mirror` default on):
  the handmade reload anims drive JointPos on the hidden native viewmodel; those joints
  are now mirrored onto the visible proxy each frame.

### Added
- Archetype-family frob detection (FROB_TARGET_LIBRARY): containers, controllers,
  stations, computers etc. are recognized even when FrobInfo bits/name hints miss.
- `set ss2fa_explain <objid>` — one-shot console dump of the full selection verdict
  for any object (works in or out of Freelook).
- **Feel options** (all off/neutral by default, community-requested):
  - `hide_crosshair_idle` — hide the crosshair when not free-aiming (hipfire style).
  - `edge_pan_press_type=hold_pan` — static camera by default, pan only while the key is held.
  - `edge_pan_mouse_delta` (+`_gain`) — at a pinned reticle edge, reclaim the clamped
    mouse motion as extra turn rate.
  - `weapon_recenter_on_release` (+`weapon_recenter_ms`) — ease the gun back to neutral
    on free-aim release instead of snapping.
  - `weapon_center` — gun on the screen centerline (System Shock 1 style) vs right-justified;
    applies in both Freelook and normal play.

### Tooling
- LGMD builder now zeroes the v4 material-extras header fields at build time
  (stale donor `off_mat_extra` caused white/saturated shaded materials); the manual
  patch step is no longer required for fresh exports.

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
