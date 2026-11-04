import glob
import os
import plistlib
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
SYSTEM_INTENT = re.compile(r'^IN[A-Z]\w*Intent$')


def intents_service_supported_intents(build_text):
    supported = set()
    for marker in re.finditer(r'<key>NSExtensionPointIdentifier</key>\s*<string>com\.apple\.intents-service</string>', build_text):
        start = build_text.rfind('<key>NSExtensionAttributes</key>', 0, marker.start())
        match = re.search(r'<key>IntentsSupported</key>\s*<array>(.*?)</array>', build_text[start:marker.start()], re.S)
        if match:
            supported.update(re.findall(r'<string>(\w+)</string>', match.group(1)))
    return supported


def vocabulary_intents(paths):
    found = {}
    for path in paths:
        with open(path, 'rb') as f:
            for phrase in plistlib.load(f).get('IntentPhrases', []):
                found.setdefault(phrase['IntentName'], []).append(os.path.relpath(path, ROOT))
    return found


class SiriVocabularyTests(unittest.TestCase):
    def test_every_vocabulary_phrase_names_an_intent_the_siri_extension_supports(self):
        with open(os.path.join(ROOT, 'Telegram', 'BUILD'), encoding='utf-8') as f:
            supported = intents_service_supported_intents(f.read())
        self.assertIn('INSendMessageIntent', supported)
        paths = glob.glob(os.path.join(ROOT, 'Telegram', 'Telegram-iOS', '*.lproj', 'AppIntentVocabulary.plist'))
        self.assertTrue(paths)
        unsupported = {name: files for name, files in vocabulary_intents(paths).items()
                       if SYSTEM_INTENT.match(name) and name not in supported}
        self.assertEqual(unsupported, {}, 'App Store Connect rejects a phrase for an intent the extension does not support (ITMS-90626)')


if __name__ == '__main__':
    unittest.main()
