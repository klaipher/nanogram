import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
IOS = os.path.join(ROOT, 'Telegram', 'Telegram-iOS')
ICON = os.path.join(IOS, 'Nanogram.icon')
PRIMARY = 'NanogramSphere'
GRAY, RGB, GRAY_ALPHA, RGBA = 0, 2, 4, 6


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def png_header(path):
    with open(path, 'rb') as f:
        data = f.read(33)
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    width, height, depth, color_type = struct.unpack('>IIBB', data[16:26])
    return width, height, color_type


def icon_layers(document):
    for group in document['groups']:
        for layer in group['layers']:
            yield group, layer


def layer_image_names(layer):
    names = set()
    if 'image-name' in layer:
        names.add(layer['image-name'])
    for specialization in layer.get('image-name-specializations', []):
        names.add(specialization['value'])
    return names


class PrimaryIconTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads(read(os.path.join(ICON, 'icon.json')))

    def test_icon_composer_document_is_layered_and_complete(self):
        groups = self.document['groups']
        self.assertTrue(1 < len(groups) <= 4, 'Icon Composer allows at most four groups')
        for _, layer in icon_layers(self.document):
            for name in layer_image_names(layer):
                self.assertTrue(os.path.isfile(os.path.join(ICON, 'Assets', name)), name)
        self.assertEqual(self.document['supported-platforms']['squares'], 'shared')

    def test_background_is_the_bottom_group_and_full_bleed(self):
        background = self.document['groups'][-1]['layers']
        self.assertEqual([layer['name'] for layer in background], ['Background'])
        for name in layer_image_names(background[0]):
            svg = read(os.path.join(ICON, 'Assets', name))
            self.assertNotIn('rx=', svg, name + ' is pre-rounded')
            self.assertNotIn('clip-path', svg, name + ' is pre-masked')
            self.assertRegex(svg, r'<rect width="100" height="100"', name)

    def test_dark_and_tinted_variants_exist(self):
        appearances = {
            specialization.get('appearance')
            for _, layer in icon_layers(self.document)
            for specialization in layer.get('image-name-specializations', [])
        }
        self.assertTrue({'dark', 'tinted'} <= appearances, appearances)

    def test_layers_carry_no_filters_icon_composer_cannot_render(self):
        for name in os.listdir(os.path.join(ICON, 'Assets')):
            if name.endswith('.svg'):
                self.assertNotIn('<filter', read(os.path.join(ICON, 'Assets', name)), name)

    def test_raster_layers_match_the_canvas_and_keep_alpha(self):
        for _, layer in icon_layers(self.document):
            for name in layer_image_names(layer):
                if name.endswith('.png'):
                    width, height, color_type = png_header(os.path.join(ICON, 'Assets', name))
                    self.assertEqual((width, height), (1024, 1024), name)
                    self.assertIn(color_type, (GRAY_ALPHA, RGBA), name)

    def test_the_app_target_uses_the_icon_as_primary_and_lists_it_first(self):
        build = read(os.path.join(ROOT, 'Telegram', 'BUILD'))
        self.assertRegex(build, r'composer_icon_folders = \["Nanogram"\]')
        folders = re.search(r'alternate_icon_folders = \[(.*?)\]', build, re.S).group(1)
        names = re.findall(r'"(\w+)"', folders)
        self.assertEqual(names[0], PRIMARY)
        self.assertIn('NanogramComet', names, 'the previous icon stays selectable')
        for name in names:
            self.assertTrue(name.startswith('Nanogram'), name + ' is not a Nanogram icon')
            self.assertTrue(os.path.isdir(os.path.join(IOS, name + '.alticon')), name)

    def test_the_picker_selects_the_new_icon_by_default(self):
        source = read(os.path.join(ROOT, 'submodules', 'TelegramUI', 'Sources', 'AppDelegate.swift'))
        icons = re.findall(r'PresentationAppIcon\(name: "(\w+)", imageName: "(\w+)"(, isDefault: true)?\)', source)
        self.assertEqual(icons[0], (PRIMARY, PRIMARY, ', isDefault: true'))
        self.assertEqual([icon for icon in icons if icon[2]], [icons[0]])
        self.assertIn('NanogramComet', [icon[0] for icon in icons])

    def test_picker_previews_are_opaque_full_bleed_squares(self):
        folder = os.path.join(IOS, PRIMARY + '.alticon')
        expected = {'@2x': 120, '@3x': 180, 'Ipad': 76, 'Ipad@2x': 152, 'LargeIpad@2x': 167}
        for suffix, pixels in expected.items():
            width, height, color_type = png_header(os.path.join(folder, PRIMARY + suffix + '.png'))
            self.assertEqual((width, height), (pixels, pixels), suffix)
            self.assertEqual(color_type, RGB, suffix + ' must have no alpha channel')
        svg = read(os.path.join(IOS, 'AlternateIconSources', PRIMARY + '.svg'))
        self.assertNotIn('rx=', svg.replace('rx="5"', ''))
        self.assertNotIn('clip-path', svg)

    def test_watch_icon_is_the_opaque_1024_square(self):
        path = os.path.join(ROOT, 'Telegram', 'WatchApp', 'tgwatch Watch App', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon.png')
        width, height, color_type = png_header(path)
        self.assertEqual((width, height), (1024, 1024))
        self.assertEqual(color_type, RGB)

    @unittest.skipUnless(shutil.which('xcrun') and os.path.isdir('/Applications/Xcode.app'), 'needs Xcode')
    def test_actool_compiles_the_icon_with_the_ios_15_fallback(self):
        with tempfile.TemporaryDirectory() as out:
            result = subprocess.run(
                ['xcrun', 'actool', '--compile', out, '--platform', 'iphoneos', '--minimum-deployment-target', '15.0',
                 '--target-device', 'iphone', '--target-device', 'ipad', '--app-icon', 'Nanogram',
                 '--output-partial-info-plist', os.path.join(out, 'partial.plist'), ICON],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('error', (result.stdout + result.stderr).lower())
            self.assertTrue(os.path.isfile(os.path.join(out, 'Assets.car')))
            self.assertTrue(os.path.isfile(os.path.join(out, 'Nanogram60x60@2x.png')))
            self.assertTrue(os.path.isfile(os.path.join(out, 'Nanogram76x76@2x~ipad.png')))


if __name__ == '__main__':
    unittest.main()
