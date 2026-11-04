import ast
import os
import plistlib
import re
import runpy
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
BUILD = os.path.join(ROOT, 'Telegram', 'BUILD')
ENTITLEMENTS_BZL = os.path.join(ROOT, 'Telegram', 'entitlements.bzl')
BAZELRC = os.path.join(ROOT, '.bazelrc')

TEAM = 'ABCDE12345'
BUNDLE = 'org.example.App'
GROUP = 'group.' + BUNDLE
HARDENED = 'com.apple.security.hardened-process'
KEYCHAIN = 'keychain-access-groups'
EXTENSIONS = {
    'NotificationServiceExtension': 'NotificationService',
    'ShareExtension': 'Share',
    'WidgetExtension': 'Widget',
    'IntentsExtension': 'SiriIntents',
    'BroadcastUploadExtension': 'BroadcastUpload',
}


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def entitlements_module():
    return runpy.run_path(ENTITLEMENTS_BZL)


def plist_of(template):
    xml = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' + template + '</dict></plist>'
    return plistlib.loads(xml.encode())


def blocks(text, rule):
    result = {}
    for match in re.finditer(r'^' + rule + r'\(\n(.*?)^\)', text, re.S | re.M):
        name = re.search(r'name = "(\w+)"', match.group(1))
        if name:
            result[name.group(1)] = match.group(1)
    return result


class ExtensionEntitlementTests(unittest.TestCase):
    def setUp(self):
        self.bzl = entitlements_module()

    def entitlements(self, suffix, **kwargs):
        return plist_of(self.bzl['extension_entitlements'](TEAM, BUNDLE, suffix, **kwargs))

    def test_extension_gets_only_the_app_group_and_its_own_identifier(self):
        plist = self.entitlements('Widget')
        self.assertEqual(plist, {
            'com.apple.security.application-groups': [GROUP],
            'application-identifier': TEAM + '.' + BUNDLE + '.Widget',
        })

    def test_no_extension_inherits_a_keychain_group(self):
        for suffix in ('NotificationService', 'Share', 'Widget', 'SiriIntents', 'BroadcastUpload'):
            self.assertNotIn(KEYCHAIN, self.entitlements(suffix))

    def test_extra_fragments_are_added_after_the_base_keys(self):
        extra = '<key>com.apple.developer.usernotifications.communication</key><true/>'
        plist = self.entitlements('NotificationService', extras=[extra])
        self.assertIs(plist['com.apple.developer.usernotifications.communication'], True)
        self.assertEqual(plist['com.apple.security.application-groups'], [GROUP])

    def test_build_file_and_bzl_parse(self):
        ast.parse(read(BUILD))
        ast.parse(read(ENTITLEMENTS_BZL))

    def test_every_extension_in_the_build_file_has_explicit_entitlements(self):
        build = read(BUILD)
        extensions = blocks(build, 'ios_extension')
        self.assertEqual(set(extensions), set(EXTENSIONS))
        for name, body in extensions.items():
            self.assertRegex(body, r'entitlements = [":\w]+\.entitlements', name + ' has no entitlements attribute')
            self.assertNotIn('provisioning_profile = None', body)

    def test_each_extension_fragment_uses_its_own_bundle_suffix(self):
        build = read(BUILD)
        fragments = blocks(build, 'plist_fragment')
        for name, body in blocks(build, 'ios_extension').items():
            target = re.search(r'entitlements = ":(\w+)\.entitlements"', body).group(1)
            self.assertIn(target, fragments, name)
            self.assertIn('extension_entitlements(telegram_team_id, telegram_bundle_id, "%s"' % EXTENSIONS[name],
                          re.sub(r'\s+', ' ', fragments[target]).replace('( ', '('), name)

    def test_only_notification_service_asks_for_more_than_the_group(self):
        build = read(BUILD)
        fragments = blocks(build, 'plist_fragment')
        extensions = blocks(build, 'ios_extension')
        for name, suffix in EXTENSIONS.items():
            target = re.search(r'entitlements = ":(\w+)\.entitlements"', extensions[name]).group(1)
            extras = 'extras' in fragments[target]
            self.assertEqual(extras, suffix == 'NotificationService', name)


class EnhancedSecurityTests(unittest.TestCase):
    def setUp(self):
        self.bzl = entitlements_module()

    def test_soft_mode_entitlements(self):
        plist = plist_of(self.bzl['enhanced_security_fragment']())
        self.assertIs(plist[HARDENED], True)
        self.assertEqual(plist[HARDENED + '.enhanced-security-version-string'], '1')
        self.assertIs(plist[HARDENED + '.checked-allocations'], True)
        self.assertIs(plist[HARDENED + '.checked-allocations.soft-mode'], True)
        self.assertNotIn(HARDENED + '.dyld-ro', plist)
        self.assertNotIn(HARDENED + '.platform-restrictions-string', plist)

    def test_platform_restrictions_are_a_separate_opt_in(self):
        plist = plist_of(self.bzl['enhanced_security_restrictions_fragment']())
        self.assertEqual(plist[HARDENED + '.platform-restrictions-string'], '2')
        self.assertIs(plist[HARDENED + '.dyld-ro'], True)
        self.assertNotIn(HARDENED, plist)

    def test_off_by_default_and_wired_to_app_notification_service_and_share(self):
        build = read(BUILD)
        for flag in ('enhancedSecurity', 'enhancedSecurityRestrictions'):
            self.assertRegex(build, r'bool_flag\(\n    name = "%s",\n    build_setting_default = False,' % flag)
        self.assertRegex(build, r'enhanced_security_select = select\(\{\n    ":enhancedSecuritySetting": enhanced_security_fragment\(\),\n    "//conditions:default": "",')
        self.assertIn('":enhancedSecurityRestrictionsSetting": enhanced_security_restrictions_fragment()', build)
        fragments = blocks(build, 'plist_fragment')
        for target in ('TelegramEntitlements', 'NotificationServiceEntitlements', 'ShareExtensionEntitlements'):
            self.assertIn('enhanced_security_select', fragments[target], target)
        for target in ('WidgetEntitlements', 'IntentsEntitlements', 'BroadcastUploadEntitlements'):
            self.assertNotIn('enhanced_security', fragments[target], target)


class CompilerHardeningTests(unittest.TestCase):
    def setUp(self):
        self.rc = [line.strip() for line in read(BAZELRC).splitlines() if not line.strip().startswith('#')]

    def test_zero_initialised_automatic_variables(self):
        self.assertIn('build --copt=-ftrivial-auto-var-init=zero', self.rc)

    def test_libcxx_fast_hardening(self):
        self.assertIn('build --copt=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST', self.rc)

    def test_strong_stack_protector(self):
        self.assertIn('build --copt=-fstack-protector-strong', self.rc)

    def test_build_tools_are_not_hardened(self):
        for line in self.rc:
            self.assertFalse(line.startswith('build --host_copt') and 'ftrivial' in line)


if __name__ == '__main__':
    unittest.main()
