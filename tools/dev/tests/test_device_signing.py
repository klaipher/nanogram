import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import device_signing  # noqa: E402


class ExportedIpaTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix='device-signing-test-')
        self.addCleanup(shutil.rmtree, self.out, True)

    def touch(self, name):
        open(os.path.join(self.out, name), 'w').close()

    def test_the_exported_ipa_is_found_under_the_app_name(self):
        self.touch('Nanogram.ipa')
        self.touch('DistributionSummary.plist')
        self.assertEqual(device_signing.exported_ipa(self.out), os.path.join(self.out, 'Nanogram.ipa'))

    def test_no_exported_ipa_stops_the_upload(self):
        with self.assertRaises(SystemExit):
            device_signing.exported_ipa(self.out)

    def test_two_exported_ipas_stop_the_upload(self):
        self.touch('Nanogram.ipa')
        self.touch('Telegram.ipa')
        with self.assertRaises(SystemExit):
            device_signing.exported_ipa(self.out)


if __name__ == '__main__':
    unittest.main()


class GeneratedEntitlementsTests(unittest.TestCase):
    # The main app is signed with com.apple.developer.usernotifications.communication (Telegram/BUILD), so its
    # development profile must grant it or the phone refuses the install (0xe8008015). Xcode only adds a
    # capability to the team profile when the generated project asks for it.
    def test_the_main_app_asks_for_communication_notifications(self):
        plist = device_signing.entitlements_plist(['group.org.klaipher.Nanogram'], push=True, communication=True)
        self.assertIn('com.apple.developer.usernotifications.communication', plist)

    def test_extensions_do_not_ask_for_communication_notifications(self):
        plist = device_signing.entitlements_plist(['group.org.klaipher.Nanogram'], push=False)
        self.assertNotIn('com.apple.developer.usernotifications.communication', plist)
