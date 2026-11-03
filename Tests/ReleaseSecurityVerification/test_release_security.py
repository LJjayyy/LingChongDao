import importlib.util
import io
import pathlib
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('release_security', pathlib.Path(__file__).resolve().parents[2] / 'scripts/verify-release-security.py')
security = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security)


class ReleaseSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / 'Release.app'
        (self.root / 'Contents/MacOS').mkdir(parents=True)
        self.metadata('release')
        (self.root / 'Contents/MacOS/LingChongDao').write_bytes(b'clean binary fixture')

    def metadata(self, configuration):
        metadata = {'CFBundleIdentifier': 'local.lingchongdao.app'}
        if configuration is not None:
            metadata['LingChongDaoBuildConfiguration'] = configuration
        (self.root / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))

    def archive(self, name, content, symlink=False):
        target = self.root / 'Contents/plugin.zip'
        with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            info = zipfile.ZipInfo(name)
            if symlink:
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, content)

    def test_clean_release_passes(self):
        self.archive('plugin/bin/helper', b'clean helper')
        self.assertEqual(security.inspect_app(self.root), [])

    def test_debug_and_missing_provenance_rejected(self):
        for value in ('debug', None):
            self.metadata(value)
            self.assertTrue(any('provenance' in e for e in security.inspect_app(self.root)))

    def test_binary_home_is_rejected_without_echo(self):
        (self.root / 'Contents/MacOS/LingChongDao').write_bytes(b'\x00/Users/private-fixture/Project/main.swift\x00')
        errors = security.inspect_app(self.root)
        self.assertTrue(any('local user directory' in e for e in errors))
        self.assertNotIn('private-fixture', '\n'.join(errors))

    def test_build_checkout_path_is_rejected(self):
        (self.root / 'Contents/MacOS/LingChongDao').write_bytes(security.PROJECT_DIRECTORY + b'/Sources/main.swift')
        self.assertTrue(any('build checkout path' in e for e in security.inspect_app(self.root)))

    def test_zip_helper_is_scanned(self):
        self.archive('plugin/bin/helper', b'/home/private-fixture/src/main.swift')
        self.assertTrue(any('local user directory' in e for e in security.inspect_app(self.root)))

    def test_private_artifact_rejected(self):
        self.archive('plugin/.env', b'fixture')
        self.assertTrue(any('private/local artifact' in e for e in security.inspect_app(self.root)))

    def test_zip_traversal_and_symlink_rejected(self):
        for name, symlink in [('../escape', False), ('/absolute', False), ('plugin/link', True)]:
            self.archive(name, b'target', symlink)
            self.assertTrue(any('unsafe archive member' in e for e in security.inspect_app(self.root)))

    def test_filesystem_symlink_rejected(self):
        (self.root / 'Contents/link').symlink_to('/tmp')
        self.assertTrue(any('symlink' in e for e in security.inspect_app(self.root)))

    def framework(self):
        framework = self.root / 'Contents/Frameworks/Sparkle.framework'
        version = framework / 'Versions/B'
        (version / 'Resources').mkdir(parents=True)
        (version / 'Sparkle').write_bytes(b'clean framework')
        (framework / 'Versions/Current').symlink_to('B')
        (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
        (framework / 'Resources').symlink_to('Versions/Current/Resources')
        return framework, version

    def test_standard_framework_links_pass_and_contents_are_scanned(self):
        _, version = self.framework()
        self.assertEqual(security.inspect_app(self.root), [])
        (version / 'Resources/private.pem').write_bytes(b'fixture')
        self.assertTrue(any('private/local artifact' in e for e in security.inspect_app(self.root)))

    def test_framework_escape_broken_and_unexpected_links_rejected(self):
        framework, version = self.framework()
        for destination in ('/tmp', '../../../../../../tmp', 'missing'):
            link = framework / 'Versions/Current'
            link.unlink()
            link.symlink_to(destination)
            self.assertTrue(any('symlink' in e for e in security.inspect_app(self.root)))
        (framework / 'Versions/Current').unlink()
        (framework / 'Versions/Current').symlink_to('B')
        (version / 'alias').symlink_to('Sparkle')
        self.assertTrue(any('symlink' in e for e in security.inspect_app(self.root)))

    def test_framework_version_directory_cannot_escape(self):
        framework, version = self.framework()
        import shutil
        shutil.rmtree(version)
        version.symlink_to(self.root / 'Contents/MacOS')
        self.assertTrue(any('symlink' in e for e in security.inspect_app(self.root)))

    def test_secret_inside_nested_archive_rejected(self):
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, 'w') as z:
            z.writestr('plugin/material', b'-----BEGIN ' + b'PRIVATE KEY-----')
        self.archive('plugin/nested.zip', nested.getvalue())
        self.assertTrue(any('private key' in e for e in security.inspect_app(self.root)))


if __name__ == '__main__':
    unittest.main()
