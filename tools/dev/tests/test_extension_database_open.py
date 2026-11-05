import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))

# Spec I-26: an extension opens the account manager with the failable open and answers without an account when
# it returns nil; only the app itself (AppDelegate) keeps the crash-and-relaunch policy.
EXTENSIONS = {
    'NotificationService': 'Telegram/NotificationService/Sources/NotificationService.swift',
    'Share': 'submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift',
    'SiriIntents': 'Telegram/SiriIntents/IntentHandler.swift',
}


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as f:
        return f.read()


class ExtensionDatabaseOpenTests(unittest.TestCase):
    def test_extensions_use_the_failable_open(self):
        for name, path in EXTENSIONS.items():
            text = read(path)
            self.assertIn('setupExtensionAccountManager(', text, name)
            self.assertIsNone(re.search(r'\bsetupAccountManager\(', text), name + ' still uses the trapping open')

    def test_the_failable_open_result_is_never_unwrapped_by_force(self):
        for name, path in EXTENSIONS.items():
            for line in read(path).splitlines():
                if 'setupExtensionAccountManager(' in line:
                    self.assertNotIn(')!', line, name)
                    self.assertTrue('guard let' in line or '?' in line, name)

    def test_notification_service_hands_back_the_alert_when_the_open_fails(self):
        text = read(EXTENSIONS['NotificationService'])
        failure = re.search(r'setupExtensionAccountManager\(.*?else \{(.*?)\n        \}', text, re.S)
        self.assertIsNotNone(failure)
        self.assertIn('completed()', failure.group(1))
        self.assertIn('return nil', failure.group(1))

    def test_share_shows_the_authorization_alert_when_the_open_fails(self):
        text = read(EXTENSIONS['Share'])
        failure = re.search(r'setupExtensionAccountManager\(.*?else \{(.*?)\n            \}', text, re.S)
        self.assertIsNotNone(failure)
        self.assertIn('Share_AuthTitle', failure.group(1))
        self.assertIn('completeRequest', failure.group(1))
        self.assertIn('return', failure.group(1))

    def test_only_the_app_keeps_the_trapping_open(self):
        found = []
        for base in ('Telegram', 'submodules'):
            for dirpath, _, files in os.walk(os.path.join(ROOT, base)):
                for file in files:
                    if file.endswith('.swift') and 'Tests' not in dirpath:
                        path = os.path.join(dirpath, file)
                        with open(path, encoding='utf-8', errors='ignore') as f:
                            if re.search(r'= setupAccountManager\(', f.read()):
                                found.append(os.path.relpath(path, ROOT))
        self.assertEqual(['submodules/TelegramUI/Sources/AppDelegate.swift'], found)


if __name__ == '__main__':
    unittest.main()
