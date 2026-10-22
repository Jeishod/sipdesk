"""Network-free packaged i18n and live UI checks; never opens capture or Keychain."""
import json
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = Path(os.environ.get('SIPDESK_TEST_APP', ROOT / 'build/i18n/SIPDesk.app'))
LANGUAGES = ['en', 'ru', 'kk', 'pt', 'es', 'fr', 'de', 'zh', 'hi', 'ar']


class LocalizationIntegrationTests(unittest.TestCase):
    def test_sources_use_catalog_keys_without_unwrapped_russian(self):
        catalog = json.loads((ROOT / 'Sources/SIPCore/Localization/en.json').read_text())
        used = set()
        for source in (ROOT / 'Sources').rglob('*.swift'):
            text = source.read_text()
            used.update(re.findall(r'\bL\("([^"\\]*)"', text))
            if source.name != 'AppLanguage.swift':
                self.assertNotRegex(text, '[А-Яа-яЁё]', source.name)
        self.assertTrue(used <= catalog.keys(), sorted(used - catalog.keys()))

    def test_packaged_catalogs_and_permission_descriptions_are_complete(self):
        resources = APP / 'Contents/Resources'
        bundles = list(resources.glob('*.bundle'))
        self.assertEqual(len(bundles), 1)
        catalog_root = next(bundles[0].rglob('en.json')).parent
        english = json.loads((catalog_root / 'en.json').read_text())
        for language in LANGUAGES:
            catalog = json.loads((catalog_root / f'{language}.json').read_text())
            self.assertEqual(set(catalog), set(english))
            self.assertTrue(all(value.strip() for value in catalog.values()))
            path = resources / f'{language}.lproj/InfoPlist.strings'
            descriptions = plistlib.loads(path.read_bytes())
            self.assertEqual(set(descriptions), {'NSMicrophoneUsageDescription', 'NSLocalNetworkUsageDescription'})
            self.assertTrue(all(descriptions.values()))

    def test_every_language_renders_and_switches_without_changing_call(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as directory:
            for language in LANGUAGES:
                with self.subTest(language=language):
                    result = subprocess.run([str(APP / 'Contents/MacOS/SIPDesk'), '--render-preview', str(Path(directory) / f'{language}.png'), '--preview-language', language, '--verify-i18n'], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(f'Localization verified: {language}', result.stdout)
                    self.assertTrue((Path(directory) / f'{language}.png').exists())


if __name__ == '__main__':
    unittest.main()
