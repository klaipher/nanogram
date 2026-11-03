"""Tests for tools/dev/lint/branding.py. Run: python3 -m unittest discover -s tools/dev/lint/tests

`test_repository_is_branded` is the guard itself: it fails when an identity key names Telegram again,
an identity key disappears upstream, or Telegram's artwork comes back.
"""

import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import branding  # noqa: E402


class BrandingRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = branding.Rules()

    def test_rules_are_read_from_the_swift_module(self):
        self.assertIn('EnterPasscode.TouchId', self.rules.identity_keys)
        self.assertIn('AuthSessions.HeaderInfo', self.rules.rewrite_only_keys)
        self.assertIn('Telegram', self.rules.tokens)
        self.assertIn('Telegram Premium', self.rules.protected)

    # Same fixtures as NanogramBrandingTests.swift: the Python copy of the rules must agree.
    def test_branded_matches_the_app(self):
        cases = [
            ('Unlock Telegram', 'Unlock Nanogram'),
            ('فتح قفل تيليجرام', 'فتح قفل Nanogram'),
            ('Разблокировать Телеграмм', 'Разблокировать Nanogram'),
            ('Telegram Premium stays, Telegram goes', 'Telegram Premium stays, Nanogram goes'),
            ('Telegram Webinar, Telegram Web-Version', 'Nanogram Webinar, Telegram Web-Version'),
            ('[desktop.telegram.org]()', '[github.com/klaipher/nanogram-releases]()'),
        ]
        for value, expected in cases:
            self.assertEqual(self.rules.branded(value), expected, value)
        self.assertEqual(self.rules.branded('[Telegram Desktop](desktop) Telegram', replacing_tokens=False),
                         '[Nanogram Desktop](desktop) Telegram')

    def test_table_problems_catch_a_regression(self):
        table = {key: 'Nanogram' for key in self.rules.identity_keys + self.rules.rewrite_only_keys}
        self.assertEqual(branding.table_problems(self.rules, table, 'fixture'), [])
        table['EnterPasscode.TouchId'] = 'Unlock Telegram'
        del table['Tour.Text2']
        problems = branding.table_problems(self.rules, table, 'fixture')
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any('EnterPasscode.TouchId still names Telegram' in p for p in problems))
        self.assertTrue(any('Tour.Text2 is missing' in p for p in problems))

    def test_plural_forms_are_checked(self):
        table = {key: 'Nanogram' for key in self.rules.identity_keys + self.rules.rewrite_only_keys}
        del table['Tour.Text2']
        table['Tour.Text2_1'] = 'Nanogram'
        table['Tour.Text2_any'] = 'Telegram'
        problems = branding.table_problems(self.rules, table, 'fixture')
        self.assertEqual(problems, ['fixture: Tour.Text2_any still names Telegram: Telegram'])

    def test_literal_problems(self):
        source = '\n'.join([
            'Text("Log in to Telegram by QR Code")',
            '// Text("Telegram in a comment")',
            'return "joined Telegram"',
            'Text("Open Nanogram or Telegram on your phone")',
            'Text("Telegram Premium")',
        ])
        problems = branding.literal_problems(self.rules, 'x.swift', source)
        self.assertEqual(problems, ['x.swift:1: user-facing text names Telegram: "Log in to Telegram by QR Code"'])

    def test_artwork_is_found_by_content(self):
        directory = tempfile.mkdtemp(prefix='branding-test-')
        self.addCleanup(shutil.rmtree, directory)
        path = os.path.join(directory, 'renamed.png')
        with open(path, 'wb') as f:
            f.write(b'plane')
        digest = branding.sha256(path)
        with mock.patch.dict(branding.FORBIDDEN_ARTWORK, {digest: 'test plane'}):
            problems = branding.artwork_problems([directory])
        self.assertEqual(len(problems), 1)
        self.assertIn('test plane', problems[0])

    def test_repository_is_branded(self):
        self.assertEqual(branding.source_problems(self.rules), [])


if __name__ == '__main__':
    unittest.main()
