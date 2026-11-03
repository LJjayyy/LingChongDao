#!/usr/bin/env python3
"""Sign the exact DMG, verify against the app's public key, and build its appcast."""
import argparse
import base64
import copy
import datetime
import email.utils
import html
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
REPOSITORY = 'LJjayyy/LingChongDao'
FEED_URL = f'https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml'
ET.register_namespace('sparkle', SPARKLE)


def field(name):
    return f'{{{SPARKLE}}}{name}'


def decoded(value, length, label):
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError(f'{label} is invalid') from None
    if len(result) != length:
        raise ValueError(f'{label} has invalid length')
    return result


def version_tuple(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value):
        raise ValueError('version must be x.y.z')
    return tuple(map(int, value.split('.')))


def previous_items(path, build, version):
    if path is None:
        return []
    data = path.read_bytes()
    if len(data) > 2 * 1024 * 1024 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('previous appcast is unsafe or too large')
    root = ET.fromstring(data)
    if root.tag != 'rss' or root.find('channel') is None:
        raise ValueError('previous appcast has no RSS channel')
    items = root.findall('./channel/item')
    for item in items:
        old_build = item.findtext(field('version'), '')
        old_version = item.findtext(field('shortVersionString'), '')
        if not re.fullmatch(r'[1-9]\d*', old_build) or int(old_build) >= build:
            raise ValueError('build number must exceed every published build')
        if version_tuple(old_version) >= version_tuple(version):
            raise ValueError('release version must exceed every published version')
        enclosure = item.find('enclosure')
        expected_url = f'https://github.com/{REPOSITORY}/releases/download/v{old_version}/LingChongDao-{old_version}-macOS-arm64.dmg'
        if enclosure is None or enclosure.get('url') != expected_url:
            raise ValueError('previous item points outside the expected release asset')
        decoded(enclosure.get(field('edSignature')), 64, 'previous signature')
        if not re.fullmatch(r'[1-9]\d*', enclosure.get('length', '')):
            raise ValueError('previous item has invalid length')
    return [copy.deepcopy(item) for item in items]


def build_feed(metadata, dmg, signature, notes, previous=None):
    version = metadata['CFBundleShortVersionString']
    version_tuple(version)
    build_text = metadata['CFBundleVersion']
    if not re.fullmatch(r'[1-9]\d*', build_text):
        raise ValueError('build number must be a positive integer')
    if dmg.name != f'LingChongDao-{version}-macOS-arm64.dmg':
        raise ValueError('DMG name does not match app version')
    decoded(signature, 64, 'update signature')
    old_items = previous_items(previous, int(build_text), version)
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = '灵宠岛'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    ET.SubElement(channel, 'description').text = '灵宠岛正式版更新'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'灵宠岛 {version}'
    ET.SubElement(item, 'link').text = f'https://github.com/{REPOSITORY}/releases/tag/v{version}'
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, field('version')).text = build_text
    ET.SubElement(item, field('shortVersionString')).text = version
    minimum = metadata['LSMinimumSystemVersion']
    minimum = minimum + '.0' if len(minimum.split('.')) == 2 else minimum
    version_tuple(minimum)
    ET.SubElement(item, field('minimumSystemVersion')).text = minimum
    ET.SubElement(item, field('hardwareRequirements')).text = 'arm64'
    # Treat release notes as text, not arbitrary active HTML.
    ET.SubElement(item, 'description').text = '<pre>' + html.escape(notes) + '</pre>'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{dmg.name}',
        field('edSignature'): signature, 'length': str(dmg.stat().st_size),
        'type': 'application/octet-stream',
    })
    channel.extend(old_items)
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--dmg', required=True, type=Path)
    parser.add_argument('--sign-tool', required=True, type=Path)
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--previous-appcast', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        metadata = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        if (metadata.get('LingChongDaoBuildConfiguration') != 'release'
                or metadata.get('CFBundleIdentifier') != 'local.lingchongdao.app'
                or metadata.get('SUFeedURL') != FEED_URL):
            raise ValueError('app is not configured for the official release feed')
        public_key = metadata.get('SUPublicEDKey')
        decoded(public_key, 32, 'app public key')
        private_key = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
        # New Sparkle keys are a raw 32-byte seed (common_cli/Secret.swift).
        # Validate before invoking tools that may echo malformed key input.
        decoded(private_key, 32, 'SPARKLE_PRIVATE_KEY')
        safe_env = os.environ.copy()
        safe_env.pop('SPARKLE_PRIVATE_KEY', None)
        result = subprocess.run([str(args.sign_tool), '--ed-key-file', '-', '-p', str(args.dmg)],
                                input=private_key + '\n', text=True, capture_output=True, env=safe_env)
        if result.returncode:
            raise ValueError('Sparkle signing failed (tool output withheld)')
        signature = result.stdout.strip()
        decoded(signature, 64, 'update signature')
        verifier = Path(__file__).with_name('verify-update-signature.swift')
        with tempfile.TemporaryDirectory(prefix='lingchongdao-signature-cache-') as cache:
            result = subprocess.run(['swift', '-module-cache-path', cache, str(verifier),
                                     public_key, str(args.dmg), signature],
                                    capture_output=True, env=safe_env)
        if result.returncode:
            raise ValueError('signature does not match the app public key')
        data = build_feed(metadata, args.dmg, signature, args.notes.read_text(), args.previous_appcast)
        temporary = args.output.with_suffix('.xml.partial')
        temporary.write_bytes(data)
        temporary.replace(args.output)
        print('PASS signed update archive and appcast metadata')
        return 0
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f'Appcast generation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
