"""Continued processing tasks are submitted with `<bundle id>.upload.message<N>` and `.upload.story<N>`; the system rejects a
submission whose identifier is not covered by a `.*` pattern in BGTaskSchedulerPermittedIdentifiers."""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def permitted():
    with open(ROOT / "Telegram/Telegram-iOS/Info.plist", "rb") as handle:
        return plistlib.load(handle)["BGTaskSchedulerPermittedIdentifiers"]


class BackgroundTaskIdentifierTests(unittest.TestCase):
    def test_every_continued_task_prefix_has_a_wildcard_entry(self):
        source = (ROOT / "submodules/TelegramUI/Sources/SharedWakeupManager.swift").read_text()
        prefixes = set(re.findall(r'"\\\(baseAppBundleId\)\.([a-z]+\.[a-z]+)\\\(', source))
        self.assertTrue(prefixes, "no continued task identifiers found")
        entries = permitted()
        for prefix in prefixes:
            stem = prefix.rsplit(".", 1)[0]
            self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER).%s.*" % stem, entries, prefix)

    def test_refresh_stays_listed(self):
        self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER).refresh", permitted())


if __name__ == "__main__":
    unittest.main()
