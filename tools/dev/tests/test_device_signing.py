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
