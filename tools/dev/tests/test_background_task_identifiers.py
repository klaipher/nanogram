"""Continued processing tasks are submitted with `<bundle id>.upload.message<N>` and `.upload.story<N>`; the system rejects a
submission whose identifier is not covered by a `.*` pattern in BGTaskSchedulerPermittedIdentifiers. The shipped plist is the
TelegramInfoPlist template in Telegram/BUILD (Telegram-iOS/Info.plist is not used by the app target)."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def permitted():
    build = (ROOT / "Telegram/BUILD").read_text()
    block = re.search(r'name = "TelegramInfoPlist".*?<key>BGTaskSchedulerPermittedIdentifiers</key>\s*<array>(.*?)</array>', build, re.S)
    return re.findall(r"<string>(.*?)</string>", block.group(1))


class BackgroundTaskIdentifierTests(unittest.TestCase):
    def test_every_continued_task_prefix_has_a_wildcard_entry(self):
        source = (ROOT / "submodules/TelegramUI/Sources/SharedWakeupManager.swift").read_text()
        prefixes = set(re.findall(r'"\\\(baseAppBundleId\)\.([a-z]+\.[a-z]+)\\\(', source))
        self.assertTrue(prefixes, "no continued task identifiers found")
        entries = permitted()
        for prefix in prefixes:
            stem = prefix.rsplit(".", 1)[0]
            self.assertIn("{telegram_bundle_id}.%s.*" % stem, entries, prefix)


if __name__ == "__main__":
    unittest.main()
