#!/usr/bin/env python3
"""Package the tested tray app, installation notes, and build sources."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("SIPDESK_PACKAGE_APP", ROOT / "build/SIPDesk.app"))
with (APP / "Contents/Info.plist").open("rb") as file:
    VERSION = plistlib.load(file)["CFBundleShortVersionString"]
OUT = ROOT / "build/distribution"
OUT.mkdir(parents=True, exist_ok=True)
DMG = OUT / f"SIPDesk-{VERSION}-AppleSilicon.dmg"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


run("codesign", "--verify", "--strict", str(APP))
with tempfile.TemporaryDirectory(prefix="sipdesk-dmg-", dir=os.environ["TMPDIR"]) as temporary:
    work = Path(temporary)
    stage = work / "image"
    stage.mkdir()
    shutil.copytree(APP, stage / APP.name, symlinks=True)
    (stage / "Applications").symlink_to("/Applications")
    (stage / "INSTALL.txt").write_text(f"""SIPDesk — Tray edition {VERSION}
macOS 14 or later; Apple Silicon (M1/M2/M3/M4 and later). Intel is not supported.

INSTALLATION
1. Drag SIPDesk.app onto Applications.
2. Eject this disk image and launch SIPDesk from Applications.
3. Click the phone icon in the macOS menu bar. There is no Dock icon.
4. Set up your SIP line; enter the password directly in the app, never in chat.
5. BEFORE calling, open Settings > Microphone access > Allow and approve the
   macOS prompt. If denied, use the System Settings link. Calls do not request
   permission automatically.

This development build is ad-hoc signed, not Developer ID signed or notarized.
If macOS blocks it, after verifying the sender/source use System Settings >
Privacy & Security > Open Anyway, if available. Managed Macs may require IT
approval. Do not disable Gatekeeper or system security globally.

Multiple saved SIP profiles; one active line and one active call. Add/edit/switch
profiles in Settings. Profile switching is blocked during an active call.
Do not run another SIPDesk instance with
the same line. Closing the panel keeps the line active; the power button quits.
Passwords are in macOS Keychain. Settings and call history stay on this Mac.
No real SIP credentials or call history are included in this disk image.

LICENSING
SipDesk is GPL-2.0-or-later. See LICENSE and NOTICE in the source archive.
PJSIP is GPL v2-or-later / commercial dual licensed. No commercial PJSIP license
is included. Review the applicable distribution terms before redistributing.
Build sources and the pinned upstream source archive are included in Sources/;
component notices are in the app's Contents/Resources/Licenses directory.
""", encoding="utf-8")
    source_dir = stage / "Sources"
    source_dir.mkdir()
    with tarfile.open(source_dir / "SIPDesk-build-sources.tar.gz", "w:gz") as archive:
        for entry in ["Sources", "Resources", "Scripts", "Tests", "Package.swift", "build.sh", "README.md", "THIRD_PARTY_NOTICES.md", "LICENSE", "NOTICE"]:
            path = ROOT / entry
            if path.is_dir():
                for file in sorted(path.rglob("*")):
                    if file.is_file() and "__pycache__" not in file.parts:
                        archive.add(file, arcname=str(Path("sipdesk") / file.relative_to(ROOT)), recursive=False)
            else:
                archive.add(path, arcname="sipdesk/" + entry)
    upstream = ROOT / ".dependencies/downloads/pjproject-c7fa6bfb85172f038cf37986696a16b3987391ea.tar.gz"
    shutil.copy2(upstream, source_dir / upstream.name)
    print(run("hdiutil", "create", "-volname", "SIPDesk", "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(DMG)))
    print(run("hdiutil", "verify", str(DMG)))
    # Mount the actual deliverable and execute its app in network-free preview mode.
    attach = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(DMG)], check=True, capture_output=True)
    entities = plistlib.loads(attach.stdout)["system-entities"]
    mount = next(Path(item["mount-point"]) for item in entities if "mount-point" in item)
    try:
        assert (mount / "Applications").is_symlink()
        assert os.readlink(mount / "Applications") == "/Applications"
        assert (mount / "Sources/SIPDesk-build-sources.tar.gz").is_file()
        run("codesign", "--verify", "--strict", str(mount / "SIPDesk.app"))
        original = APP / "Contents/MacOS/SIPDesk"
        packaged = mount / "SIPDesk.app/Contents/MacOS/SIPDesk"
        assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(packaged.read_bytes()).digest()
        print(run(str(packaged), "--render-preview", str(work / "packaged-preview.png"), "--verify-tray-ui"))
        print(run(str(packaged), "--render-preview", str(work / "permissions-preview.png"), "--verify-permissions"))
        print("Mounted DMG: app signature, binary hash, Applications link, sources and tray lifecycle verified.")
    finally:
        print(run("hdiutil", "detach", str(mount)))
checksum = hashlib.sha256(DMG.read_bytes()).hexdigest()
(OUT / (DMG.name + ".sha256")).write_text(checksum + "  " + DMG.name + "\n")
print(f"DMG: {DMG}\nSize: {DMG.stat().st_size / 1024 / 1024:.1f} MiB\nSHA256: {checksum}")
