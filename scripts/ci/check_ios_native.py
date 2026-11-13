#!/usr/bin/env python3
"""Fail before Xcode if native device outputs or cached bundles are incomplete."""
import pathlib
import plistlib
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPS = ROOT / "deps"
errors = []


def require_file(path):
    if not path.is_file() or path.stat().st_size == 0:
        errors.append(f"Missing or empty file: {path.relative_to(ROOT)}")
        return False
    return True


def require_arm64(path):
    if require_file(path):
        result = subprocess.run(
            ["xcrun", "lipo", "-verify_arch", "arm64", str(path)],
            capture_output=True, text=True,
        )
        if result.returncode:
            errors.append(f"Not an arm64 binary: {path.relative_to(ROOT)}: {result.stderr.strip()}")


for name in ("ish", "ish_emu", "fakefs", "ish_aot"):
    require_arm64(DEPS / "libs" / f"lib{name}.a")
require_arm64(DEPS / "lame-build/lib/libmp3lame.a")
require_file(DEPS / "include/ish/ish.h")

for name in ("FFmpeg", "libavcodec", "libavformat", "libavutil", "libavfilter", "libswresample", "libswscale", "Rclone"):
    bundle = DEPS / "frameworks" / f"{name}.xcframework"
    info = bundle / "Info.plist"
    if not require_file(info):
        continue
    try:
        with info.open("rb") as stream:
            libraries = plistlib.load(stream).get("AvailableLibraries", [])
        devices = [lib for lib in libraries if lib.get("SupportedPlatform") == "ios"
                   and not lib.get("SupportedPlatformVariant")
                   and "arm64" in lib.get("SupportedArchitectures", [])]
        if not devices:
            errors.append(f"Missing iOS arm64 device slice: {bundle.relative_to(ROOT)}")
        for lib in devices:
            binary = bundle / lib["LibraryIdentifier"] / lib["LibraryPath"]
            if binary.suffix == ".framework":
                binary = binary / binary.stem
            require_arm64(binary)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as exc:
        errors.append(f"Invalid XCFramework {name}: {exc}")

# Swift/Obj-C compile against these original framework headers, too.
require_file(DEPS / "frameworks/FFmpeg.framework/Headers/FFmpeg.h")
require_file(DEPS / "frameworks/Rclone.xcframework/ios-arm64/Headers/librclone.h")
vdso = DEPS / "resources/libvdso.so.elf"
if require_file(vdso) and vdso.read_bytes()[:4] != b"\x7fELF":
    errors.append("Guest VDSO is not ELF; check Homebrew llvm and lld")
patch = DEPS / "resources/RootfsPatch.bundle"
if not patch.is_dir() or not any(patch.iterdir()):
    errors.append("Missing or empty deps/resources/RootfsPatch.bundle")
archive = DEPS / "resources/alpine-rootfs.zip"
if require_file(archive):
    try:
        with zipfile.ZipFile(archive) as rootfs:
            names = rootfs.namelist()
            if "alpine-rootfs/meta.db" not in names or not any(n.startswith("alpine-rootfs/data/") for n in names):
                errors.append("Rootfs ZIP lacks fakefs meta.db or data directory")
            corrupt = rootfs.testzip()
            if corrupt:
                errors.append(f"Corrupt rootfs ZIP member: {corrupt}")
    except (OSError, zipfile.BadZipFile) as exc:
        errors.append(f"Invalid rootfs ZIP: {exc}")

if errors:
    for error in errors:
        print(f"::error::{error}", file=sys.stderr)
    sys.exit(1)
print("Native iOS device dependencies verified (including VDSO, AOT and rootfs)")
