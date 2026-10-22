"""Smoke checks for the menu-bar edition's packaged UI."""
import plistlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = Path(os.environ.get("SIPDESK_TEST_APP", ROOT / "build/tray/SIPDesk.app"))


class TrayUITests(unittest.TestCase):
    def test_launches_as_menu_bar_agent(self):
        with (APP / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        self.assertTrue(info.get("LSUIElement"), "App should not open a Dock window at launch")

    def test_panel_opens_for_incoming_and_url_actions(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            output = Path(directory) / "tray.png"
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(output), "--verify-tray-ui"], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("Tray lifecycle verified", result.stdout)

    def test_presence_selection(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "status.png"), "--verify-presence"], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("Presence selection verified", result.stdout)

    def test_full_hit_targets_and_tray_only_launch(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "targets.png"), "--verify-hit-targets"], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("Full hit targets and tray-only launch verified", result.stdout)

    def test_digit_click_restores_keyboard_input(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "focus.png"), "--verify-dial-focus"], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("Digit click keyboard focus verified", result.stdout)

    def test_call_keypad_fits_panel(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "call.png"), "--verify-call-layout"], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Call keypad layout verified", result.stdout)

    def test_status_menu_has_colored_indicators(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "colors.png"), "--verify-status-colors"], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Status colors verified", result.stdout)

    def test_microphone_permission_preflight(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "permissions.png"), "--verify-permissions"], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Microphone preflight verified", result.stdout)

    def test_colleague_interactions(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            result = subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(Path(directory) / "interaction.png"), "--verify-colleague-input"], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Colleague interactions verified", result.stdout)

    def test_dark_compact_preview_renders(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            output = Path(directory) / "tray.png"
            subprocess.run([str(APP / "Contents/MacOS/SIPDesk"), "--preview-language", "ru", "--render-preview", str(output)], check=True, timeout=30)
            dimensions = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(output)], text=True)
            self.assertIn("pixelWidth: 720", dimensions)
            self.assertIn("pixelHeight: 1160", dimensions)
            # NSBitmapImageRep reads the actual rendered popover background, not source strings.
            sample = subprocess.check_output(["swift", "-e", "import AppKit; let b = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!; let c = b.colorAt(x: 4, y: 600)!.usingColorSpace(.deviceRGB)!; print(Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))", str(output)], text=True)
            r, g, b = map(int, sample.split())
            self.assertLess(max(r, g, b), 90, "Popover should have a dark background")


if __name__ == "__main__":
    unittest.main()
