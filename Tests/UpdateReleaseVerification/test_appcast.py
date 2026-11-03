import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('appcast', ROOT / 'scripts/create-appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lingchongdao-update-test-')
        self.root = Path(self.temp.name)
        self.dmg = self.root / 'LingChongDao-0.1.43-macOS-arm64.dmg'
        self.dmg.write_bytes(b'isolated update fixture')
        self.metadata = {'CFBundleShortVersionString': '0.1.43', 'CFBundleVersion': '44',
                         'LSMinimumSystemVersion': '14.0'}
        self.signature = base64.b64encode(bytes(64)).decode()

    def tearDown(self):
        self.temp.cleanup()

    def feed(self, **kwargs):
        return appcast.build_feed(self.metadata, self.dmg, self.signature, '<script>unsafe</script>', **kwargs)

    def test_fixed_asset_and_requirements(self):
        item = ET.fromstring(self.feed()).find('./channel/item')
        self.assertEqual(item.findtext(appcast.field('version')), '44')
        self.assertEqual(item.findtext(appcast.field('minimumSystemVersion')), '14.0.0')
        self.assertEqual(item.find('enclosure').get('url'),
                         'https://github.com/LJjayyy/LingChongDao/releases/download/v0.1.43/' + self.dmg.name)
        self.assertNotIn('<script>', item.findtext('description'))

    def test_invalid_signature_rejected(self):
        self.signature = 'not-a-signature'
        with self.assertRaises(ValueError):
            self.feed()

    def previous(self):
        path = self.root / 'previous.xml'
        path.write_bytes(self.feed())
        return path

    def test_nonincreasing_version_or_build_rejected(self):
        previous = self.previous()
        with self.assertRaises(ValueError):
            self.feed(previous=previous)
        self.metadata['CFBundleVersion'] = '45'
        with self.assertRaises(ValueError):
            self.feed(previous=previous)

    def test_compatible_history_preserved(self):
        previous = self.previous()
        self.metadata.update(CFBundleVersion='45', CFBundleShortVersionString='0.1.44')
        self.dmg = self.root / 'LingChongDao-0.1.44-macOS-arm64.dmg'
        self.dmg.write_bytes(b'next fixture')
        root = ET.fromstring(self.feed(previous=previous))
        self.assertEqual(len(root.findall('./channel/item')), 2)

    def test_foreign_previous_asset_rejected(self):
        path = self.previous()
        path.write_bytes(path.read_bytes().replace(b'https://github.com/', b'https://attacker.test/'))
        self.metadata.update(CFBundleVersion='45', CFBundleShortVersionString='0.1.44')
        self.dmg = self.root / 'LingChongDao-0.1.44-macOS-arm64.dmg'
        self.dmg.write_bytes(b'next fixture')
        with self.assertRaises(ValueError):
            self.feed(previous=path)

    def test_dtd_rejected(self):
        path = self.root / 'previous.xml'
        path.write_text('<!DOCTYPE rss><rss><channel/></rss>')
        with self.assertRaises(ValueError):
            self.feed(previous=path)

    def test_missing_signing_key_fails_without_output(self):
        app = self.root / 'test.app'
        (app / 'Contents').mkdir(parents=True)
        metadata = {**self.metadata, 'CFBundleIdentifier': 'local.lingchongdao.app',
                    'LingChongDaoBuildConfiguration': 'release', 'SUFeedURL': appcast.FEED_URL,
                    'SUPublicEDKey': base64.b64encode(bytes(32)).decode()}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
        notes = self.root / 'notes.md'
        notes.write_text('test notes')
        output = self.root / 'appcast.xml'
        env = os.environ.copy()
        env.pop('SPARKLE_PRIVATE_KEY', None)
        result = subprocess.run(['python3', str(ROOT / 'scripts/create-appcast.py'), '--app', str(app),
                                 '--dmg', str(self.dmg), '--notes', str(notes), '--sign-tool', '/missing',
                                 '--output', str(output)], env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_real_signing_and_tamper_rejection(self):
        sign_tool = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
        if not sign_tool.exists():
            self.skipTest('Resolve the pinned Sparkle package first')
        key_file = self.root / 'test-key.json'
        swift = ['swift', '-module-cache-path', str(self.root / 'module-cache')]
        subprocess.run(swift + [str(Path(__file__).with_name('generate-test-key.swift')), str(key_file)],
                       capture_output=True, check=True)
        key = json.loads(key_file.read_text())
        result = subprocess.run([str(sign_tool), '--ed-key-file', '-', '-p', str(self.dmg)],
                                input=key['private'] + '\n', text=True, capture_output=True, check=True)
        signature = result.stdout.strip()
        command = swift + [str(ROOT / 'scripts/verify-update-signature.swift'), key['public'],
                   str(self.dmg), signature]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.dmg.write_bytes(b'tampered')
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
