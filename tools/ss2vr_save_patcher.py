#!/usr/bin/env python3
"""Offline SS2:AE save mod-loadout patcher.

This tool edits only the save header mod path table and preserves the save body
byte-for-byte. Use copied saves first until the write path has been live-tested.
"""

import argparse
import datetime as _dt
import shutil
import struct
from pathlib import Path
from typing import List, Optional, Union


DEFAULT_MOD = "kpf:/mods/ss2vr_weapon_handoff_probe"
MAGIC = b"KS2S"
SIZE_U32 = struct.Struct("<I")
SIZE_I32 = struct.Struct("<i")
SIZE_U16 = struct.Struct("<H")


class SaveFormatError(RuntimeError):
    pass


ByteData = Union[bytes, bytearray]


def _u32(data: ByteData, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise SaveFormatError(f"u32 read outside file/header at 0x{offset:X}")
    return SIZE_U32.unpack_from(data, offset)[0]


def _i32(data: ByteData, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise SaveFormatError(f"i32 read outside file/header at 0x{offset:X}")
    return SIZE_I32.unpack_from(data, offset)[0]


def _u16(data: ByteData, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise SaveFormatError(f"u16 read outside file/header at 0x{offset:X}")
    return SIZE_U16.unpack_from(data, offset)[0]


def _put_u32(data: bytearray, offset: int, value: int) -> None:
    if offset < 0 or offset + 4 > len(data):
        raise SaveFormatError(f"u32 write outside header at 0x{offset:X}")
    SIZE_U32.pack_into(data, offset, value)


def _align4(value: int) -> int:
    return (value + 3) & ~3


def normalize_mod_path(value: str) -> str:
    text = value.strip().replace("\\", "/")
    if not text:
        raise ValueError("mod path is empty")
    if text.endswith(".kpf"):
        text = text[:-4]
    if text.startswith("kpf:/mods/"):
        return text
    if text.startswith("mods/"):
        return "kpf:/" + text
    if text.startswith("/mods/"):
        return "kpf:" + text
    return "kpf:/mods/" + text


def _read_string(data: ByteData, offset: int, header_size: int) -> str:
    length = _u32(data, offset)
    start = offset + 4
    end = start + length
    if length > 4096 or end > header_size:
        raise SaveFormatError(f"bad string at 0x{offset:X} length={length}")
    return bytes(data[start:end]).decode("utf-8", errors="strict")


def _append_string(buf: bytearray, text: str) -> int:
    raw = text.encode("utf-8")
    start = len(buf)
    buf += SIZE_U32.pack(len(raw))
    buf += raw
    buf += b"\0"
    padding = _align4(len(buf)) - len(buf)
    if padding:
        buf += b"\0" * padding
    return start


class SaveHeader:
    def __init__(self, data: bytes) -> None:
        if len(data) < 0x48:
            raise SaveFormatError("file is too small to be an SS2:AE save")
        self.data = data
        self.flatbuffer_size = _u32(data, 0)
        # The first dword is the FlatBuffer size prefix, not the absolute save
        # body offset. The serialized header occupies that prefix plus the
        # reported FlatBuffer byte count.
        self.header_size = 4 + self.flatbuffer_size
        if self.header_size < 0x48 or self.header_size > len(data):
            raise SaveFormatError(f"implausible header/body offset 0x{self.header_size:X}")
        if data[8:12] != MAGIC:
            raise SaveFormatError("missing KS2S save magic")

        self.root_offset_addr = 4
        self.root_table = self.root_offset_addr + _u32(data, self.root_offset_addr)
        if self.root_table <= 0 or self.root_table + 0x28 > self.header_size:
            raise SaveFormatError(f"implausible root table offset 0x{self.root_table:X}")
        self.vtable = self.root_table - _i32(data, self.root_table)
        if self.vtable < 0 or self.vtable + 4 > self.header_size:
            raise SaveFormatError(f"implausible vtable offset 0x{self.vtable:X}")
        self.vtable_len = _u16(data, self.vtable)
        self.object_len = _u16(data, self.vtable + 2)
        if self.vtable_len < 16 or self.object_len < 4:
            raise SaveFormatError("unexpected root table/vtable shape")

        self.field0 = self._field_voffset(0)
        self.field3 = self._field_voffset(3)
        self.field5 = self._field_voffset(5)
        if not self.field0 or not self.field3 or not self.field5:
            raise SaveFormatError("save header lacks expected title/level/mod fields")
        for name, voffset in (
            ("title", self.field0),
            ("level", self.field3),
            ("mods", self.field5),
        ):
            if voffset + 4 > self.object_len:
                raise SaveFormatError(
                    f"save header {name} field at 0x{voffset:X} exceeds root object length 0x{self.object_len:X}"
                )

        self.user_title = self._read_uoffset_string(self.field0)
        self.level_title = self._read_uoffset_string(self.field3)
        self.vector_start = self._uoffset_target(self.root_table + self.field5)
        self.mods_physical = self._read_string_vector(self.vector_start)
        self.mods = list(reversed(self.mods_physical))

    def _field_voffset(self, index: int) -> int:
        slot = self.vtable + 4 + index * 2
        if slot + 2 > self.vtable + self.vtable_len:
            return 0
        return _u16(self.data, slot)

    def _uoffset_target(self, offset_addr: int) -> int:
        value = _u32(self.data, offset_addr)
        target = offset_addr + value
        if target < 0 or target >= self.header_size:
            raise SaveFormatError(
                f"bad uoffset at 0x{offset_addr:X}: +0x{value:X} -> 0x{target:X}"
            )
        return target

    def _read_uoffset_string(self, voffset: int) -> str:
        return _read_string(self.data, self._uoffset_target(self.root_table + voffset), self.header_size)

    def _read_string_vector(self, vector_start: int) -> List[str]:
        count = _u32(self.data, vector_start)
        if count > 128:
            raise SaveFormatError(f"implausible mod vector count {count}")
        values = []  # type: List[str]
        entries_start = vector_start + 4
        for i in range(count):
            entry_addr = entries_start + i * 4
            string_start = self._uoffset_target(entry_addr)
            values.append(_read_string(self.data, string_start, self.header_size))
        return values


def parse_save(path: Path) -> SaveHeader:
    return SaveHeader(path.read_bytes())


def rebuild_with_mods(header: SaveHeader, mods: List[str]) -> bytes:
    # Keep the validated root/vtable/table bytes exactly and rebuild the variable
    # vector + strings region. The save body starts at header.header_size.
    buf = bytearray(header.data[: header.vector_start])
    vector_start = len(buf)
    buf += SIZE_U32.pack(len(mods))
    entries_start = len(buf)
    buf += b"\0" * (len(mods) * 4)

    logical_string_starts = []  # type: List[int]
    for mod in mods:
        logical_string_starts.append(_append_string(buf, mod))

    level_start = _append_string(buf, header.level_title)
    title_start = _append_string(buf, header.user_title)
    new_header_size = len(buf)

    _put_u32(buf, 0, new_header_size - 4)
    _put_u32(buf, header.root_table + header.field5, vector_start - (header.root_table + header.field5))
    _put_u32(buf, header.root_table + header.field3, level_start - (header.root_table + header.field3))
    _put_u32(buf, header.root_table + header.field0, title_start - (header.root_table + header.field0))

    # FlatBuffer vectors store offsets from each vector slot. The original saves
    # were built with strings in logical load order and vector slots in reverse.
    physical_starts = list(reversed(logical_string_starts))
    for i, string_start in enumerate(physical_starts):
        entry_addr = entries_start + i * 4
        _put_u32(buf, entry_addr, string_start - entry_addr)

    return bytes(buf) + header.data[header.header_size :]


def timestamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def create_backup(path: Path, backup_dir: Optional[Path] = None) -> Path:
    target_dir = backup_dir if backup_dir is not None else path.parent
    target_dir.mkdir(parents=True, exist_ok=True)
    backup = target_dir / f"{path.name}.bak-{timestamp()}"
    shutil.copy2(path, backup)
    return backup


def command_list(args: argparse.Namespace) -> int:
    header = parse_save(Path(args.save))
    print(f"save: {args.save}")
    print(f"header_size: 0x{header.header_size:X}")
    print(f"level: {header.level_title}")
    print(f"title: {header.user_title}")
    print("mods:")
    for i, mod in enumerate(header.mods, start=1):
        print(f"  {i:02d}. {mod}")
    return 0


def command_add(args: argparse.Namespace) -> int:
    source = Path(args.save)
    header = parse_save(source)
    mod = normalize_mod_path(args.mod)
    mods = list(header.mods)

    if mod in mods:
        print(f"already present: {mod}")
        if not args.force:
            print(f"pass --force to move it to position: {args.position}")
            return 0
        mods = [m for m in mods if m != mod]

    if args.position == "first":
        mods.insert(0, mod)
    else:
        mods.append(mod)

    patched = rebuild_with_mods(header, mods)
    parse_check = SaveHeader(patched)
    if parse_check.mods != mods:
        raise SaveFormatError("internal reparse check failed after rebuilding header")

    if args.in_place:
        backup = create_backup(source, Path(args.backup_dir) if args.backup_dir else None)
        source.write_bytes(patched)
        print(f"backup: {backup}")
        print(f"patched in place: {source}")
    else:
        if args.output:
            output = Path(args.output)
        else:
            output = source.with_name(source.stem + ".ss2vrpatched" + source.suffix)
        if output.exists() and not args.overwrite:
            raise SaveFormatError(f"output exists; pass --overwrite: {output}")
        output.write_bytes(patched)
        print(f"patched copy: {output}")
        print(f"source unchanged: {source}")

    print(f"added: {mod}")
    print(f"position: {args.position}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch SS2:AE save mod loadouts offline.")
    sub = parser.add_subparsers(dest="command")
    sub.required = True

    list_cmd = sub.add_parser("list", help="list the mod loadout embedded in a save")
    list_cmd.add_argument("save", help="path to save-*.sav")
    list_cmd.set_defaults(func=command_list)

    add_cmd = sub.add_parser("add", help="add a mod path to the embedded loadout")
    add_cmd.add_argument("save", help="path to save-*.sav")
    add_cmd.add_argument("--mod", default=DEFAULT_MOD, help=f"mod path/name to add (default: {DEFAULT_MOD})")
    add_cmd.add_argument(
        "--position",
        choices=("last", "first"),
        default="last",
        help=(
            "position in the patcher list output; default last because the saved-game "
            "table's displayed order is opposite AE's effective load priority"
        ),
    )
    add_cmd.add_argument("--output", help="write patched copy here; default is *.ss2vrpatched.sav")
    add_cmd.add_argument("--overwrite", action="store_true", help="allow overwriting --output")
    add_cmd.add_argument("--in-place", action="store_true", help="patch source file after creating a backup")
    add_cmd.add_argument("--backup-dir", help="directory for in-place backups")
    add_cmd.add_argument("--force", action="store_true", help="remove/re-add if the mod is already present")
    add_cmd.set_defaults(func=command_add)

    args = parser.parse_args()
    try:
        return int(args.func(args) or 0)
    except (OSError, SaveFormatError, ValueError) as exc:
        print(f"error: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
