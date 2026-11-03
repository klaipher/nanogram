#!/usr/bin/env python3
"""Nanogram branding guard: no Telegram name where the text names this app, no Telegram logo.

  branding.py                    check the sources
  branding.py --bundle APP       also check a built Telegram.app (tg build runs this)
  branding.py --apply-en         rewrite the identity values in the bundled en table

The identity keys are the lists in submodules/NanogramBranding/Sources/NanogramIdentityKeys.swift,
which the app also applies at run time to every language pack (NanogramBranding). Tests:
python3 -m unittest discover -s tools/dev/lint/tests
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))

KEYS_SWIFT = 'submodules/NanogramBranding/Sources/NanogramIdentityKeys.swift'
BRANDING_SWIFT = 'submodules/NanogramBranding/Sources/NanogramBranding.swift'
EN_STRINGS = 'Telegram/Telegram-iOS/en.lproj/Localizable.strings'

PLURAL_SUFFIXES = ('', '_0', '_zero', '_1', '_2', '_3_10', '_many', '_any')

# Telegram's own artwork, by content (sha256). The welcome screen's plane and sphere, the
# CallKit logo and the call title logo. None of it may ship again under any name.
FORBIDDEN_ARTWORK = {
    'c28d4e5438f3a10fa1df725764b4bc897af475983070aaf08df1b631334a10a1': 'welcome screen plane',
    '621831c454689762c79c80083f797352aa420c488c19ba924da006ab533dd0bb': 'welcome screen sphere',
    '1ca444afedcbfe34d2aa22e86af466f70c9d46dd49198108a79fe40d437d4e89': 'welcome screen sphere (RMIntro copy)',
    'ad30551081c7852c8d0776360fbb30fed0ca21ef96a08b84c7bc09bac342f4ff': 'CallKit logo @2x',
    'd3f5692599ba33a620ee3a576d3dce76b8587fa4ca048fb2a017ffd14766f8ee': 'CallKit logo @3x',
    'a2a9c3cb4b640df4dd49f76edae8ede35b2454a880756d37b7725cc06131ac2a': 'call title logo',
}
# The build may recompress PNGs, so a bundle is also checked by file name.
FORBIDDEN_BUNDLE_FILES = ['telegram_plane1@2x.png', 'telegram_sphere@2x.png']

# Names of that artwork the code must not load any more.
FORBIDDEN_REFERENCES = [
    ('@"telegram_plane1.png"', 'Telegram plane on the welcome screen'),
    ('@"telegram_sphere.png"', 'Telegram sphere on the welcome screen'),
    ('"Call/CallKitLogo"', 'Telegram plane in CallKit'),
    ('"Call/CallTitleLogo"', 'Telegram plane next to the call status'),
    ('"https://getdesktop.telegram.org"', "Telegram's desktop download instead of Nanogram's releases"),
]

# Telegram's plane still drawn in places the owner has not decided on yet (round-video
# watermark, QR code centres). Reported, not failed.
PENDING_ARTWORK = [
    'Telegram/Telegram-iOS/Resources/PlaneLogo.tgs',
    'Telegram/Telegram-iOS/Resources/PlaneLogoPlain.tgs',
]

# Files outside the strings table that name the app.
NON_TABLE_GLOBS = [
    ('Telegram/Telegram-iOS', 'InfoPlist.strings'),
    ('Telegram/Telegram-iOS', 'AppIntentVocabulary.plist'),
    ('Telegram/Share', 'Localizable.strings'),
    ('Telegram/WidgetKitWidget', 'Localizable.strings'),
]

# Swift files whose user-facing literals name the app, and the literals that name the
# network and stay.
LITERAL_FILES = [
    'submodules/WidgetItems/Sources/WidgetItems.swift',
    'submodules/AuthorizationUI/Sources/AuthorizationSequencePhoneEntryControllerNode.swift',
]
WATCH_SOURCES = 'Telegram/WatchApp/tgwatch Watch App'
ALLOWED_LITERALS = {
    'joined Telegram',      # service message: the user joined the network
    'Telegram message',     # login code delivered in the Telegram service chat
}
# Parts of a literal that name the network on purpose.
ALLOWED_PHRASES = [
    'or Telegram on your phone',   # QR login: the phone may run Nanogram or Telegram (owner decision)
]


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as f:
        return f.read()


def swift_list(source, name):
    """The quoted strings between `// BEGIN <name>` and `// END <name>`."""
    m = re.search(r'// BEGIN ' + re.escape(name) + r'\n(.*?)// END ' + re.escape(name), source, re.S)
    if not m:
        raise SystemExit('branding: no "%s" list in %s' % (name, KEYS_SWIFT))
    return re.findall(r'^\s*"([^"]+)",', m.group(1), re.M)


def swift_strings(source, name):
    """The string literals of `static let <name>: [String] = [...]`."""
    m = re.search(r'static let ' + name + r': \[String\] = \[(.*?)\n    \]', source, re.S)
    if not m:
        raise SystemExit('branding: no %s in %s' % (name, BRANDING_SWIFT))
    return re.findall(r'"([^"]+)"', m.group(1))


class Rules:
    """The same rules NanogramBranding applies at run time, read from its source."""

    def __init__(self):
        keys = read(KEYS_SWIFT)
        self.identity_keys = swift_list(keys, 'identity keys')
        self.rewrite_only_keys = swift_list(keys, 'rewrite-only keys')
        branding = read(BRANDING_SWIFT)
        self.tokens = swift_strings(branding, 'tokens')
        self.protected = swift_strings(branding, 'protectedPhrases')
        address = re.search(r'static let releasesAddress = "([^"]+)"', branding).group(1)
        self.rewrites = [(m, address) for m in ('getdesktop.telegram.org', 'desktop.telegram.org')]
        self.rewrites.append(('Telegram Desktop', 'Nanogram Desktop'))

    def branded(self, value, replacing_tokens=True):
        rules = [(m, r, False) for m, r in self.rewrites]
        if replacing_tokens:
            rules += [(p, p, True) for p in self.protected]
            rules += [(t, 'Nanogram', False) for t in self.tokens]
        out, i = [], 0
        while i < len(value):
            for match, replacement, whole_word in rules:
                if value.startswith(match, i):
                    end = i + len(match)
                    if whole_word and end < len(value) and value[end].isalpha():
                        continue
                    out.append(replacement)
                    i = end
                    break
            else:
                out.append(value[i])
                i += 1
        return ''.join(out)

    def strip_protected(self, value):
        for phrase in self.protected:
            value = re.sub(re.escape(phrase) + r'(?![^\W\d_])', '', value)
        return value


STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def parse_strings(text):
    """Key -> (line index, value) for a .strings file in the one-entry-per-line form."""
    entries = {}
    for i, line in enumerate(text.split('\n')):
        m = STRINGS_LINE.match(line)
        if m:
            entries[m.group(1)] = (i, m.group(2))
    return entries


def table_problems(rules, table, where):
    """Identity keys that are missing from `table` or still name Telegram there."""
    problems = []
    for key in rules.identity_keys + rules.rewrite_only_keys:
        forms = [key + s for s in PLURAL_SUFFIXES if key + s in table]
        if not forms:
            problems.append('%s: identity key %s is missing (renamed upstream? update %s)' % (where, key, KEYS_SWIFT))
            continue
        identity = key in rules.identity_keys
        for form in forms:
            value = table[form]
            if rules.branded(value, replacing_tokens=identity) != value:
                problems.append('%s: %s still names Telegram: %s' % (where, form, value))
    return problems


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def artwork_problems(directories):
    problems = []
    for directory in directories:
        for dirpath, _, filenames in os.walk(directory):
            for name in filenames:
                if not name.lower().endswith(('.png', '.pdf', '.jpg')):
                    continue
                path = os.path.join(dirpath, name)
                what = FORBIDDEN_ARTWORK.get(sha256(path))
                if what:
                    problems.append('%s is Telegram artwork (%s)' % (os.path.relpath(path, ROOT), what))
    return problems


def reference_problems():
    problems = []
    for needle, what in FORBIDDEN_REFERENCES:
        result = subprocess.run(['git', 'grep', '-n', '-F', '--untracked', needle, '--', 'submodules', 'Telegram'],
                                cwd=ROOT, capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if 'tools/dev/lint/' in line:
                continue
            problems.append('%s loads %s' % (line.split(':', 2)[0] + ':' + line.split(':', 2)[1], what))
    return problems


def literal_problems(rules, path, text):
    problems = []
    for number, line in enumerate(text.split('\n'), 1):
        if line.lstrip().startswith('//'):
            continue
        for literal in re.findall(r'"((?:[^"\\\n]|\\.)*)"', line):
            if literal in ALLOWED_LITERALS:
                continue
            checked = rules.strip_protected(literal)
            for phrase in ALLOWED_PHRASES:
                checked = checked.replace(phrase, '')
            if any(t in checked for t in rules.tokens):
                problems.append('%s:%d: user-facing text names Telegram: "%s"' % (path, number, literal))
    return problems


def source_problems(rules):
    problems = []
    en = {k: v for k, (_, v) in parse_strings(read(EN_STRINGS)).items()}
    problems += table_problems(rules, en, EN_STRINGS)

    for directory, filename in NON_TABLE_GLOBS:
        base = os.path.join(ROOT, directory)
        for lproj in sorted(os.listdir(base)):
            path = os.path.join(base, lproj, filename)
            if not lproj.endswith('.lproj') or not os.path.exists(path):
                continue
            for number, line in enumerate(read(path).split('\n'), 1):
                if any(t in rules.strip_protected(line) for t in rules.tokens):
                    problems.append('%s:%d: names Telegram: %s' % (os.path.relpath(path, ROOT), number, line.strip()))

    build = read('Telegram/BUILD')
    for m in re.finditer(r'<key>(CFBundleName|CFBundleDisplayName|\w+UsageDescription)</key>\s*<string>([^<]*)</string>', build):
        # TelegramCore, TelegramUI, ... are framework (module) names, not the app's.
        if re.search(r'(?<![\w.])(?:%s)(?!\w)' % '|'.join(map(re.escape, rules.tokens)), m.group(2)):
            problems.append('Telegram/BUILD: %s is "%s"' % (m.group(1), m.group(2)))
    project = read('Telegram/WatchApp/project.yml')
    for m in re.finditer(r'^\s*(CFBundleDisplayName|\w+UsageDescription): (.*)$', project, re.M):
        if any(t in m.group(2) for t in rules.tokens):
            problems.append('Telegram/WatchApp/project.yml: %s is "%s"' % (m.group(1), m.group(2)))

    for path in LITERAL_FILES:
        problems += literal_problems(rules, path, read(path))
    for dirpath, _, filenames in os.walk(os.path.join(ROOT, WATCH_SOURCES)):
        for name in sorted(filenames):
            if name.endswith('.swift'):
                path = os.path.relpath(os.path.join(dirpath, name), ROOT)
                problems += literal_problems(rules, path, read(path))

    problems += reference_problems()
    problems += artwork_problems([os.path.join(ROOT, 'Telegram/Telegram-iOS'),
                                  os.path.join(ROOT, 'submodules/TelegramUI/Images.xcassets')])
    return problems


def plist_json(path):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit('branding: cannot read %s: %s' % (path, result.stderr.strip()))
    return json.loads(result.stdout)


def bundle_problems(rules, app):
    problems = []
    if not os.path.isdir(app):
        return ['no bundle at %s' % app]
    en = os.path.join(app, 'en.lproj', 'Localizable.strings')
    problems += table_problems(rules, plist_json(en), en)
    bundles = [app]
    plugins = os.path.join(app, 'PlugIns')
    if os.path.isdir(plugins):
        bundles += [os.path.join(plugins, p) for p in sorted(os.listdir(plugins)) if p.endswith('.appex')]
    for bundle in bundles:
        info = plist_json(os.path.join(bundle, 'Info.plist'))
        for key, value in info.items():
            if (key in ('CFBundleName', 'CFBundleDisplayName') or key.endswith('UsageDescription')) and \
                    isinstance(value, str) and any(t in value for t in rules.tokens):
                problems.append('%s: Info.plist %s is "%s"' % (os.path.relpath(bundle, app), key, value))
    for name in ('nanogram_sphere@2x.png', 'nanogram_comet@2x.png'):
        if not os.path.exists(os.path.join(app, name)):
            problems.append('%s is missing from the bundle (welcome screen)' % name)
    for name in FORBIDDEN_BUNDLE_FILES:
        if os.path.exists(os.path.join(app, name)):
            problems.append('%s is in the bundle (Telegram artwork)' % name)
    problems += artwork_problems([app])
    return problems


def apply_en(rules):
    """Brands the identity values of the bundled en table in place."""
    path = os.path.join(ROOT, EN_STRINGS)
    lines = read(EN_STRINGS).split('\n')
    changed = 0
    for key, (index, value) in parse_strings('\n'.join(lines)).items():
        base = next((key[:-len(s)] for s in PLURAL_SUFFIXES if s and key.endswith(s)), key)
        for candidate in (key, base):
            if candidate in rules.identity_keys or candidate in rules.rewrite_only_keys:
                branded = rules.branded(value, replacing_tokens=candidate in rules.identity_keys)
                if branded != value:
                    # Every line of the key, in case the table defines it twice.
                    for i, line in enumerate(lines):
                        if line.startswith('"%s" = ' % key):
                            lines[i] = line.replace('"%s";' % value, '"%s";' % branded)
                    changed += 1
                break
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    return changed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--bundle', help='also check this built Telegram.app')
    parser.add_argument('--apply-en', action='store_true', help='brand the identity values of the bundled en table')
    args = parser.parse_args(argv)
    rules = Rules()
    if args.apply_en:
        print('branding: %d en values rewritten' % apply_en(rules))
        return 0
    problems = source_problems(rules)
    if args.bundle:
        problems += bundle_problems(rules, args.bundle)
    for path in PENDING_ARTWORK:
        if os.path.exists(os.path.join(ROOT, path)):
            print('branding: pending owner decision, still Telegram\'s plane: %s' % path)
    for problem in problems:
        print('branding: ' + problem, file=sys.stderr)
    if problems:
        print('branding: %d problem(s). Rules: %s' % (len(problems), KEYS_SWIFT), file=sys.stderr)
        return 1
    print('branding: OK (%d identity keys)' % len(rules.identity_keys))
    return 0


if __name__ == '__main__':
    sys.exit(main())
