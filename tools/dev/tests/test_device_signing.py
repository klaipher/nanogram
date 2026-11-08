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


class PayloadAppNameTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        os.makedirs(os.path.join(self.root, 'Payload'))

    def test_the_renamed_bundle_is_found(self):
        os.makedirs(os.path.join(self.root, 'Payload', 'Nanogram.app'))
        self.assertEqual(device_signing.payload_app_name(self.root), 'Nanogram.app')

    def test_an_ipa_from_before_the_rename_still_works(self):
        os.makedirs(os.path.join(self.root, 'Payload', 'Telegram.app'))
        self.assertEqual(device_signing.payload_app_name(self.root), 'Telegram.app')

    def test_no_app_or_two_apps_stop(self):
        with self.assertRaises(SystemExit):
            device_signing.payload_app_name(self.root)
        os.makedirs(os.path.join(self.root, 'Payload', 'Nanogram.app'))
        os.makedirs(os.path.join(self.root, 'Payload', 'Telegram.app'))
        with self.assertRaises(SystemExit):
            device_signing.payload_app_name(self.root)


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


class EnhancedSecurityEntitlementsTests(unittest.TestCase):
    # Enhanced Security (soft mode) is on the App IDs of the app, NotificationService and Share since 2026-11-05;
    # Telegram/entitlements.bzl signs those three with it, so their development profiles must grant it.
    KEYS = ['com.apple.security.hardened-process', 'com.apple.security.hardened-process.checked-allocations']

    def test_hardened_targets_ask_for_enhanced_security(self):
        for suffix in ['', '.NotificationService', '.Share']:
            self.assertTrue(device_signing.wants_enhanced_security('org.klaipher.Nanogram' + suffix, 'org.klaipher.Nanogram'))
        plist = device_signing.entitlements_plist(['group.org.klaipher.Nanogram'], push=False, enhanced_security=True)
        for key in self.KEYS:
            self.assertIn(key, plist)

    def test_other_extensions_do_not(self):
        for suffix in ['.Widget', '.SiriIntents', '.BroadcastUpload', '.NotificationContent']:
            self.assertFalse(device_signing.wants_enhanced_security('org.klaipher.Nanogram' + suffix, 'org.klaipher.Nanogram'))
        self.assertNotIn(self.KEYS[0], device_signing.entitlements_plist(['g'], push=False))


class EnhancedSecurityVerificationTests(unittest.TestCase):
    # tg testflight re-signs for distribution; the three hardened bundles must keep the entitlements, and
    # their distribution profiles must grant them, or the upload is stopped.
    APP = 'org.klaipher.Nanogram'
    FULL = dict(device_signing.ENHANCED_SECURITY_REQUIRED)

    def make_app(self, suffixes=('.NotificationService', '.Share', '.Widget')):
        import plistlib
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        app = os.path.join(root, 'Nanogram.app')
        bundles = {self.APP: app}
        os.makedirs(app)
        for suffix in suffixes:
            appex = os.path.join(app, 'PlugIns', suffix[1:] + '.appex')
            os.makedirs(appex)
            bundles[self.APP + suffix] = appex
        for bundle_id, path in bundles.items():
            with open(os.path.join(path, 'Info.plist'), 'wb') as f:
                plistlib.dump({'CFBundleIdentifier': bundle_id}, f)
        return app, {path: bundle_id for bundle_id, path in bundles.items()}

    def problems(self, app, names, signed, profile, check_profiles=True):
        return device_signing.app_enhanced_security_problems(
            app, check_profiles,
            entitlements_of=lambda path: signed(names[path]),
            profile_of=lambda path: profile(names[path]))

    def test_everything_present_has_no_problems(self):
        app, names = self.make_app()
        full_profile = {device_signing.HARDENED_PROCESS_KEY: True}
        self.assertEqual([], self.problems(app, names, lambda b: self.FULL, lambda b: full_profile))

    def test_a_resign_that_drops_the_entitlements_is_reported_per_bundle(self):
        app, names = self.make_app()
        signed = lambda b: {} if b.endswith('.Share') else self.FULL
        problems = self.problems(app, names, signed, lambda b: {device_signing.HARDENED_PROCESS_KEY: True})
        self.assertEqual(4, len(problems))
        self.assertTrue(all(p.startswith(self.APP + '.Share:') and 'signed without' in p for p in problems))

    def test_a_distribution_profile_without_the_capability_is_reported(self):
        app, names = self.make_app()
        profile = lambda b: {} if b == self.APP else {device_signing.HARDENED_PROCESS_KEY: True}
        problems = self.problems(app, names, lambda b: self.FULL, profile)
        self.assertEqual([self.APP + ': its provisioning profile does not grant com.apple.security.hardened-process'], problems)

    def test_a_missing_profile_is_reported_when_profiles_are_checked(self):
        app, names = self.make_app()
        problems = self.problems(app, names, lambda b: self.FULL, lambda b: None)
        self.assertEqual(3, len(problems))
        self.assertTrue(all('no embedded provisioning profile' in p for p in problems))

    def test_profiles_are_not_read_before_export(self):
        app, names = self.make_app()
        self.assertEqual([], self.problems(app, names, lambda b: self.FULL, lambda b: self.fail('read'), check_profiles=False))

    def test_a_missing_extension_is_reported(self):
        app, names = self.make_app(suffixes=('.NotificationService', '.Widget'))
        problems = self.problems(app, names, lambda b: self.FULL, lambda b: {device_signing.HARDENED_PROCESS_KEY: True})
        self.assertEqual([self.APP + '.Share: the bundle is not in the app'], problems)

    def test_the_wrong_version_string_is_reported(self):
        app, names = self.make_app()
        signed = lambda b: dict(self.FULL, **{'com.apple.security.hardened-process.enhanced-security-version-string': '2'})
        problems = self.problems(app, names, signed, lambda b: {device_signing.HARDENED_PROCESS_KEY: True})
        self.assertEqual(3, len(problems))

    def test_require_stops_the_upload_loudly(self):
        app, names = self.make_app()
        with self.assertRaises(SystemExit) as raised:
            device_signing.require_enhanced_security(app, True, 'in the exported App Store build',
                                                     entitlements_of=lambda p: {}, profile_of=lambda p: {})
        self.assertIn('Nothing was uploaded', str(raised.exception))
        self.assertIn('TG_TF_ENHANCED_SECURITY=0', str(raised.exception))
