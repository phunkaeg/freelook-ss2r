==============================================================
 FREELOOK MODE for System Shock 2: 25th Anniversary Remaster
 v1.0.0
==============================================================

Free-aim like the original System Shock (1994): press F5 and
move the crosshair independently of the camera. The view edge-pans when the reticle
reaches the screen border. Works with all guns, projectiles,
melee (wrench included), muzzle flash, and object selection.
Resolution-independent: the HUD overlay space is auto-calibrated
at runtime (tested at 1920x1080 and 3440x1440 ultrawide).

--- WHAT'S IN THE ZIP ---------------------------------------
FreelookLoader.exe       starts the game with the mod loaded
Launch Freelook.bat      double-click alternative to the loader
FlatAim.dll              the mod itself (loaded by the loader)
flataim.ini              tuning knobs (sensible defaults)
FreelookSavePatcher.exe  adds the mod to EXISTING save games
mods\flataim.kpf         the in-game script package
README.txt               this file

--- INSTALL -------------------------------------------------
1. Copy FreelookLoader.exe, "Launch Freelook.bat", FlatAim.dll
   and flataim.ini into the game folder
   (the folder containing SystemShock2Remastered.exe).
2. Copy flataim.kpf into the game's "mods" folder.
3. Start the game ONE of these ways:
   a) double-click "Launch Freelook.bat" (or FreelookLoader.exe), or
   b) Steam > SS2 Remastered > Properties > Launch Options:
        "C:\full\path\to\FreelookLoader.exe" %command%
      then launch from Steam normally, forever.
4. EXISTING SAVES ONLY: run FreelookSavePatcher.exe once. It
   lists your saves BY NAME, you pick which to patch (or A for
   all), and it BACKS UP every save it touches
   (*.pre-freelook.bak, plus the patcher's own backup) before
   adding the mod. New games need no patching.

--- USE -----------------------------------------------------
F5          toggle Freelook on/off (rebindable, see below)
Mouse       moves the crosshair; the view edge-pans at borders
flataim.ini sensitivity, edge-pan feel, weapon pivot, melee
            placement - documented inline. Re-read every time
            you toggle Freelook on; no restart needed.

--- REBINDING THE TOGGLE ------------------------------------
In flataim.ini, set toggle_vk to a Windows virtual-key code
(hex). Default: toggle_vk=0x74 (F5). Common codes:

  Key            Code  |  Key            Code
  ---------------------+----------------------
  F1 .. F12   0x70..0x7B  (F5 = 0x74)
  Mouse middle    0x04  |  Tab            0x09
  Mouse back/X1   0x05  |  Caps Lock      0x14
  Mouse fwd/X2    0x06  |  Tilde ~        0xC0
  0 .. 9      0x30..0x39 |  Space          0x20
  A .. Z      0x41..0x5A  (A=0x41, B=0x42 ... V=0x56, Z=0x5A)

Full list: search "Windows virtual key codes" (VK_*).
Left/right mouse buttons (0x01/0x02) are not recommended -
they are the fire/use buttons. Change takes effect next launch
(or next Freelook toggle if already running).

--- UNINSTALL -----------------------------------------------
Delete the five files from the game folder and
mods\flataim.kpf. To un-patch a save, restore its
*.pre-freelook.bak (rename back to the original name).
Remove the Steam launch option if you set it.

--- TROUBLESHOOTING -----------------------------------------
* F5 does nothing: check flataim.log in the game folder.
  "waiting for SS2FA Squirrel bridge" = mods\flataim.kpf is not
  loading - for an existing save, run FreelookSavePatcher.exe.
* Crosshair off-centre: should not happen (auto-calibration).
  Send flataim.log and your resolution.
* Saves not found by the patcher: it resolves your real Windows
  "Saved Games" folder (including relocated/OneDrive profiles);
  if yours still is not found it will ask for the path.
* Antivirus flags the loader/DLL: false positive common to all
  injection-based game mods. Source code: [REPO URL].
  VirusTotal: [LINK].

--- KNOWN ISSUES --------------------------------------------
* None blocking at release.
* Report issues at [REPO URL]/issues - include flataim.log.

--- CREDITS -------------------------------------------------
Code & design: [YOUR NAME/HANDLE]
Built with MinHook (c) Tsuda Kageyu (BSD-2-Clause, license incl.)
Thanks: the Nightdive Discord community for the original request.
Not affiliated with Nightdive Studios. Use at your own risk.
