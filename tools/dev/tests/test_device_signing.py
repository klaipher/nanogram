import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import device_signing  # noqa: E402


class TestflightWorkFilesTests(unittest.TestCase):
    # Each upload staged a ~1.9 GB archive and .ipa in TMPDIR and never removed it: 13 uploads filled 24 GB.
    def make_work(self):
        work = tempfile.mkdtemp(prefix='testflight-test-')
        self.addCleanup(shutil.rmtree, work, True)
        os.makedirs(os.path.join(work, 'Nanogram.xcarchive'))
        return work

    def test_an_uploaded_build_leaves_no_work_files(self):
        work = self.make_work()
        device_signing.finish_testflight_work(work, uploaded=True)
        self.assertFalse(os.path.exists(work))

    def test_an_export_only_build_keeps_the_signed_package(self):
        work = self.make_work()
        message = device_signing.finish_testflight_work(work, uploaded=False)
        self.assertTrue(os.path.isdir(work))
        self.assertIn(work, message)


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


class WatchProfilesTests(unittest.TestCase):
    # IOS-WATCH-WIDGET-1: `profiles` must register the watch app, its widget extension and the watch App Group, which
    # Xcode only does for a bundle that asks for the group in its entitlements.
    APP = 'org.klaipher.Nanogram'

    def test_the_watch_app_and_the_widget_get_profiles(self):
        found = {name: bundle for name, bundle, _ in device_signing.profile_targets(self.APP)}
        self.assertEqual(found['WatchApp'], self.APP + '.watchkitapp')
        self.assertEqual(found['WatchWidget'], self.APP + '.watchkitapp.widget')
        self.assertEqual(found['Telegram'], self.APP)
        self.assertEqual(len(found), len(set(found.values())))

    def test_the_main_app_comes_first_because_its_id_names_the_groups(self):
        self.assertEqual(device_signing.profile_targets(self.APP)[0], ('Telegram', self.APP, True))

    def test_the_watch_pair_asks_for_the_watch_group_only(self):
        for suffix in ['.watchkitapp', '.watchkitapp.widget']:
            self.assertEqual(device_signing.target_groups(self.APP + suffix, self.APP), ['group.org.klaipher.Nanogram.watch'])

    def test_everything_else_keeps_the_phone_group(self):
        for suffix in ['', '.Share', '.Widget', '.NotificationService']:
            self.assertEqual(device_signing.target_groups(self.APP + suffix, self.APP), ['group.org.klaipher.Nanogram'])

    def test_the_watch_pair_asks_for_no_push_or_phone_capabilities(self):
        for name, bundle, push in device_signing.profile_targets(self.APP):
            if name.startswith('Watch'):
                self.assertFalse(push)
                self.assertFalse(device_signing.wants_enhanced_security(bundle, self.APP))
                self.assertFalse(device_signing.wants_time_sensitive(bundle, self.APP))

    def test_the_generated_project_writes_the_group_into_the_watch_entitlements(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, True)
        device_signing.write_project(directory, 'TEAM', device_signing.profile_targets(self.APP))
        for name in ['WatchApp', 'WatchWidget']:
            with open(os.path.join(directory, name + '.entitlements')) as f:
                text = f.read()
            self.assertIn('<string>group.org.klaipher.Nanogram.watch</string>', text)
            self.assertNotIn('<string>group.org.klaipher.Nanogram</string>', text)
            self.assertNotIn('aps-environment', text)
        with open(os.path.join(directory, 'App.xcodeproj', 'project.pbxproj')) as f:
            project = f.read()
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "org.klaipher.Nanogram.watchkitapp.widget"', project)

    def test_the_source_entitlements_use_the_same_group(self):
        root = os.path.join(os.path.dirname(__file__), '..', '..', '..', 'Telegram', 'WatchApp', 'WatchWidget')
        for name in ['WatchApp.entitlements', 'WatchWidget.entitlements']:
            with open(os.path.join(root, name)) as f:
                self.assertIn(device_signing.watch_app_group(self.APP), f.read())


class TimeSensitiveEntitlementsTests(unittest.TestCase):
    KEY = 'com.apple.developer.usernotifications.time-sensitive'

    def test_the_app_and_the_notification_service_ask_for_time_sensitive(self):
        for suffix in ['', '.NotificationService']:
            self.assertTrue(device_signing.wants_time_sensitive('org.klaipher.Nanogram' + suffix, 'org.klaipher.Nanogram'))
        plist = device_signing.entitlements_plist(['group.org.klaipher.Nanogram'], push=False, time_sensitive=True)
        self.assertIn(self.KEY, plist)

    def test_other_extensions_do_not(self):
        for suffix in ['.Share', '.Widget', '.SiriIntents', '.BroadcastUpload', '.NotificationContent']:
            self.assertFalse(device_signing.wants_time_sensitive('org.klaipher.Nanogram' + suffix, 'org.klaipher.Nanogram'))
        self.assertNotIn(self.KEY, device_signing.entitlements_plist(['group.org.klaipher.Nanogram'], push=False))


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
