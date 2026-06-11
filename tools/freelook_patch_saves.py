"""Freelook save patcher — friendly interactive wrapper around ss2vr_save_patcher.

Scans the default SS2R saved-games folder, lists the saves it finds (with the
in-game save name when it can be read from the file, else the filename), lets
the player pick by number (or A = all), BACKS UP each save beside the original
(.pre-freelook.bak), then adds flataim.kpf to the save's mod table via the
existing, proven patcher logic. Ship as a PyInstaller onefile exe.
"""
import argparse
import contextlib
import io
import re
import shutil
import sys
from pathlib import Path

import ss2vr_save_patcher as patcher  # proven patch logic; imported so PyInstaller bundles it

MOD = "flataim.kpf"


def saved_games_root() -> Path:
    """Resolve the REAL Saved Games folder via the Windows known-folder API
    (FOLDERID_SavedGames), so relocated/redirected profiles (folder moved via
    Properties->Location, OneDrive profile backup, etc.) still resolve. Falls
    back to %USERPROFILE%\\Saved Games."""
    try:
        import ctypes
        from ctypes import wintypes
        fid = (ctypes.c_byte * 16).from_buffer_copy(
            bytes.fromhex("ff325c4c9dbbb043b5b42d72e54eaaa4"))  # {4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4} little-endian
        out = ctypes.c_wchar_p()
        if ctypes.windll.shell32.SHGetKnownFolderPath(ctypes.byref(fid), 0, None, ctypes.byref(out)) == 0:
            path = Path(out.value)
            ctypes.windll.ole32.CoTaskMemFree(out)
            return path
    except Exception:
        pass
    return Path.home() / "Saved Games"


SAVES = saved_games_root() / "Nightdive Studios" / "System Shock 2 Remastered"


def display_name(sav: Path) -> str:
    # Save header = chain of u32-length-prefixed ASCII strings (mod kpf paths,
    # then LEVEL name, then SAVE name), 4-byte aligned, followed by a u32 and the
    # zstd magic 28 B5 2F FD. The in-game save name is the LAST string in the
    # chain (verified across save-0/1/2/quick). Slots: save-N.sav = slot N+1.
    try:
        head = sav.read_bytes()[:2048]
        pos = head.find(b"kpf:/")
        strings = []
        if pos >= 4:
            pos -= 4
            while pos + 4 <= len(head):
                ln = int.from_bytes(head[pos:pos + 4], "little")
                if not (0 < ln < 256) or pos + 4 + ln > len(head):
                    break
                raw = head[pos + 4:pos + 4 + ln].split(b"\x00", 1)[0]
                try:
                    text = raw.decode("ascii")
                except UnicodeDecodeError:
                    break
                if not text or not all(0x20 <= ord(c) <= 0x7E for c in text):
                    break
                strings.append(text)
                pos += 4 + ((ln + 4) & ~3)  # string + NUL terminator, padded to 4 bytes
        names = [s for s in strings if not s.startswith("kpf:")]
        if names:
            name = names[-1]
            level = names[-2] if len(names) >= 2 else ""
            m = re.match(r"save-(\d+)\.sav$", sav.name, re.I)
            slot = f"slot {int(m.group(1)) + 1}, " if m else ""
            suffix = f" - {level}" if level and level != name else ""
            return f"{name}{suffix}  ({slot}{sav.name})"
    except OSError:
        pass
    return sav.name


def main() -> int:
    folder = SAVES if SAVES.is_dir() else Path(input(f"Saves folder not found at {SAVES}.\nEnter your saves folder path: ").strip('" '))
    saves = sorted(folder.glob("*.sav"))
    if not saves:
        input("No .sav files found. Press Enter to exit.")
        return 1
    print("\nFreelook save patcher — adds the Freelook mod to existing saves.")
    print("A backup (.pre-freelook.bak) is made next to every save it touches.\n")
    for i, s in enumerate(saves, 1):
        print(f"  {i}. {display_name(s)}")
    pick = input("\nPatch which saves? (numbers like 1,3 or A for all, Enter to cancel): ").strip().lower()
    if not pick:
        return 0
    chosen = saves if pick == "a" else [saves[int(n) - 1] for n in re.findall(r"\d+", pick) if 0 < int(n) <= len(saves)]
    ok = 0
    for s in chosen:
        bak = s.with_suffix(s.suffix + ".pre-freelook.bak")
        if not bak.exists():
            shutil.copy2(s, bak)
        ns = argparse.Namespace(save=str(s), mod=MOD, position="last",
                                output=None, overwrite=False, in_place=True, force=False)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                rc = patcher.command_add(ns)
            status = "OK" if rc == 0 else f"FAILED ({buf.getvalue().strip()[:120]})"
        except Exception as e:
            rc = 1
            status = f"FAILED ({e})"
        if rc == 0:
            ok += 1
        print(f"  {s.name}: {status}")
    print(f"\nDone: {ok}/{len(chosen)} patched. Backups: *.pre-freelook.bak in the same folder.")
    input("Press Enter to exit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
