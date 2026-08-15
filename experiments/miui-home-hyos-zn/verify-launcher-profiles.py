#!/usr/bin/env python3
"""Verify launcher profile RVAs and fingerprints against local ELF files."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


PT_LOAD = 1
PF_X = 1


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_bytes(value: str) -> bytes:
    return bytes.fromhex(value)


def load_segments(data: bytes) -> list[tuple[int, int, int, int]]:
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("expected a little-endian ELF64 image")
    program_offset = struct.unpack_from("<Q", data, 0x20)[0]
    entry_size = struct.unpack_from("<H", data, 0x36)[0]
    entry_count = struct.unpack_from("<H", data, 0x38)[0]
    if entry_size < 56:
        raise ValueError("invalid ELF64 program-header size")
    result = []
    for index in range(entry_count):
        offset = program_offset + index * entry_size
        p_type, flags, file_offset, virtual_address = struct.unpack_from(
            "<IIQQ", data, offset
        )
        file_size = struct.unpack_from("<Q", data, offset + 32)[0]
        if p_type == PT_LOAD:
            result.append((virtual_address, file_offset, file_size, flags))
    return result


def rva_to_file_offset(
    rva: int,
    size: int,
    segments: list[tuple[int, int, int, int]],
    require_executable: bool = False,
) -> int:
    for virtual_address, file_offset, file_size, flags in segments:
        if require_executable and not flags & PF_X:
            continue
        delta = rva - virtual_address
        if delta >= 0 and delta + size <= file_size:
            return file_offset + delta
    raise ValueError(f"RVA 0x{rva:x} (+0x{size:x}) is outside file-backed LOAD data")


def verify_bytes(
    profile_id: str,
    label: str,
    rva: int,
    expected: bytes,
    image: bytes,
    segments: list[tuple[int, int, int, int]],
) -> None:
    file_offset = rva_to_file_offset(
        rva, len(expected), segments, require_executable=True
    )
    actual = image[file_offset : file_offset + len(expected)]
    if actual != expected:
        raise ValueError(
            f"{profile_id} {label} mismatch at RVA 0x{rva:x}: "
            f"expected {expected.hex()}, got {actual.hex()}"
        )


def verify_profile(profile: dict, library_path: Path) -> None:
    image = library_path.read_bytes()
    profile_id = profile["id"]
    digest = hashlib.sha256(image).hexdigest()
    if digest.lower() != profile["library_sha256"].lower():
        raise ValueError(
            f"{profile_id} library SHA-256 mismatch: expected "
            f"{profile['library_sha256']}, got {digest}"
        )
    segments = load_segments(image)
    for fingerprint in profile["identity_fingerprints"]:
        verify_bytes(
            profile_id,
            f"identity/{fingerprint['name']}",
            parse_int(fingerprint["offset"]),
            parse_bytes(fingerprint["bytes"]),
            image,
            segments,
        )
    for label in ("side_handler", "pointer_handler", "touch_processor"):
        hook = profile.get(label)
        if hook is None:
            continue
        expected = parse_bytes(hook["bytes"])
        verify_bytes(
            profile_id,
            label,
            parse_int(hook["offset"]),
            expected,
            image,
            segments,
        )
    print(f"{profile_id}: PASS {library_path} sha256={digest}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("launcher-profiles.json"),
    )
    parser.add_argument(
        "--library",
        action="append",
        required=True,
        metavar="PROFILE_ID=PATH",
    )
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    profiles = {profile["id"]: profile for profile in manifest["profiles"]}
    for binding in args.library:
        profile_id, separator, raw_path = binding.partition("=")
        if not separator or profile_id not in profiles:
            raise ValueError(f"invalid --library binding: {binding}")
        verify_profile(profiles[profile_id], Path(raw_path))


if __name__ == "__main__":
    main()
