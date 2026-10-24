"""Verify a macOS-built device app and produce an unsigned sideloading IPA."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile


EXPECTED_BUNDLE = "io.github.metammy07.litetale"
ALTERNATE_ICONS = {"AppIconBlue", "AppIconRose", "AppIconOrange", "AppIconTeal", "AppIconGreen"}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def package(app, output):
    if sys.platform != "darwin":
        raise RuntimeError("Run packaging on the macOS builder after the iPhoneOS build.")
    app = app.resolve(strict=True)
    output = output.resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE:
        raise ValueError("The app has an unexpected Bundle ID.")
    if info.get("CFBundleDisplayName") != "LiteTale":
        raise ValueError("The app has an unexpected display name.")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("Expected an iPhoneOS device build, not a simulator app.")
    if set(info.get("UIDeviceFamily", [])) != {1, 2}:
        raise ValueError("The app must support both iPhone and iPad.")
    executable = app / info["CFBundleExecutable"]
    architectures = command("xcrun", "lipo", "-archs", str(executable)).split()
    if architectures != ["arm64"]:
        raise ValueError(f"Expected device arm64, received {architectures}.")
    platform = command("xcrun", "vtool", "-show-build", str(executable))
    if "platform IOS" not in platform or "IOSSIMULATOR" in platform:
        raise ValueError("Mach-O build platform is not iOS device.")
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        if set(info.get(key, {}).get("CFBundleAlternateIcons", {})) != ALTERNATE_ICONS:
            raise ValueError(f"Missing alternate icon configuration: {key}")
    assets = app / "Frameworks/App.framework/flutter_assets"
    for relative in ("AssetManifest.bin", "lib/assets/fonts/LXGWNeoZhiSongPlus.ttf"):
        if not (assets / relative).is_file():
            raise ValueError(f"Missing Flutter resource: {relative}")
    # CocoaPods may force-load the static Rust archive into its plugin framework
    # rather than Runner. Both are loaded into the app process for Dart FFI.
    bridge_binary = None
    candidates = [executable]
    for framework in (app / "Frameworks").glob("*.framework"):
        binary = framework / framework.stem
        if binary.is_file():
            candidates.append(binary)
    for binary in candidates:
        symbols = command("xcrun", "nm", "-gU", str(binary))
        if "frb_" in symbols:
            bridge_binary = str(binary.relative_to(app))
            break
    if bridge_binary is None:
        raise ValueError("Rust bridge symbols are missing from the packaged application.")
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    if not all(part.isdigit() for part in version.split(".")) or not build.isdigit():
        raise ValueError("Unexpected app version/build format.")
    output.mkdir(parents=True, exist_ok=True)
    staging = output / "package" / "Payload"
    if staging.exists():
        raise FileExistsError("Use a fresh packaging directory; existing artifacts are retained.")
    staging.mkdir(parents=True)
    shutil.copytree(app, staging / "Runner.app", symlinks=True)
    ipa = output / f"LiteTale-{version}-ios-{build}-unsigned.ipa"
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(staging), str(ipa)], check=True)
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA archive integrity check failed.")
        packaged = plistlib.loads(archive.read("Payload/Runner.app/Info.plist"))
        if packaged["CFBundleIdentifier"] != EXPECTED_BUNDLE:
            raise ValueError("Packaged application identity does not match.")
    with ipa.open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    manifest = {
        "file": ipa.name,
        "sha256": digest,
        "bytes": ipa.stat().st_size,
        "version": version,
        "ios_build": build,
        "bundle_id": EXPECTED_BUNDLE,
        "architectures": architectures,
        "platform": "iphoneos",
        "device_families": info["UIDeviceFamily"],
        "rust_bridge_binary": bridge_binary,
        "minimum_os_version": info.get("MinimumOSVersion"),
        "xcode": command("xcodebuild", "-version"),
        "flutter": json.loads(command("flutter", "--version", "--machine")),
        "rust": command("rustc", "--version"),
        "commit": os.environ.get("GITHUB_SHA", command("git", "rev-parse", "HEAD")),
        "workflow_run": os.environ.get("GITHUB_RUN_ID"),
        "signing": "unsigned; sign on Windows before installing",
        "device_tested": False,
        "known_limitations": [
            "Native Liquid Glass, edge-back gestures and source switching require iPhone/iPad acceptance.",
            "iOS local EPUB uses the system document share to open in Apple Books; the user chooses Books. Android keeps the in-app CSS reader.",
            "iOS uses ordinary page turns; simulated page curl is removed. Android keeps its existing reader.",
            "Online sessions, font import and volume keys require physical-device validation.",
        ],
    }
    (output / "ipa-verification.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (output / "INSTALL.txt").write_text(
        "LiteTale iOS preview / iPhone + iPad\n"
        "This IPA is unsigned. Sign and install using Sideloadly on Windows.\n"
        "Keep the same Apple Account and Bundle ID for future updates; do not uninstall to refresh signing.\n"
        "Use the included verification manifest for the exact source, version and limitations.\n"
        "See the separate simulator acceptance results; physical-device behavior still needs acceptance.\n",
        encoding="utf-8",
    )
    print(json.dumps({"ipa": str(ipa), "sha256": manifest["sha256"], "bytes": manifest["bytes"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app, args.output)
