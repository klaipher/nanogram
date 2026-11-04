"""Every reader of the stored auto-download settings is either a display-only screen or applies the Lockdown policy.

`effectiveMediaAutoDownloadSettings(stored:autodownload:policy:)` and `MediaAutoDownloadSettings.hardened(by:)` apply
`HardenedMediaPolicy`. Decoding the stored entry anywhere else bypasses it: the live settings were once rebuilt
without the policy (7250fa8e), which undid the launch hardening at the first emission. A new reader that drives
downloads would fail here instead of silently auto-downloading under Lockdown Mode. The Mac has the same guard
(tools/dev/tests/test_hardened_media_readers.py).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RAW_DECODE = re.compile(r"\.get\(MediaAutoDownloadSettings\.self\)")

# Policy homes: they decode and harden (checked below).
POLICY_HOME = {
    "submodules/TelegramUIPreferences/Sources/MediaAutoDownloadSettings.swift",
    "submodules/TelegramPresentationData/Sources/PresentationData.swift",
    "submodules/TelegramUI/Sources/SharedAccountContext.swift",
}
# Readers that only show or edit the stored choice, or use it for something that is not a download decision.
DISPLAY_ONLY = {
    "submodules/ChatListUI/Sources/ChatListControllerNode.swift": "chat-list preload switch",
    "submodules/PasscodeUI/Sources/PasscodeEntryControllerNode.swift": "energy settings on the passcode screen",
    "submodules/TelegramUI/Sources/StoreDownloadedMedia.swift": "saves files that are already downloaded",
    "submodules/TelegramUI/Components/StorageUsageScreen/Sources/DataUsageScreen.swift": "shows the stored choice",
    "submodules/SettingsUI/Sources/Data and Storage/AutodownloadConnectionTypeController.swift": "settings screen",
    "submodules/SettingsUI/Sources/Data and Storage/AutodownloadMediaCategoryController.swift": "settings screen",
    "submodules/SettingsUI/Sources/Data and Storage/DataAndStorageSettingsController.swift": "settings screen",
    "submodules/SettingsUI/Sources/Data and Storage/EnergySavingSettingsScreen.swift": "settings screen",
    "submodules/SettingsUI/Sources/Search/SettingsSearchableItems.swift": "settings search",
}


def swift_sources():
    for top in ("submodules", "Telegram"):
        base = ROOT / top
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            parts = path.relative_to(ROOT).parts
            if "Tests" in parts or "node_modules" in parts or ".build" in parts:
                continue
            yield path


class HardenedMediaReaderTests(unittest.TestCase):
    def test_stored_settings_are_only_decoded_where_the_policy_is_applied_or_nothing_downloads(self):
        offenders = []
        for path in swift_sources():
            relative = path.relative_to(ROOT).as_posix()
            if relative in POLICY_HOME or relative in DISPLAY_ONLY:
                continue
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if RAW_DECODE.search(line) and not line.lstrip().startswith("//"):
                    offenders.append(f"{relative}:{number}")
        self.assertEqual(
            offenders,
            [],
            "decode through effectiveMediaAutoDownloadSettings(...) or .hardened(by:); add a display-only screen to DISPLAY_ONLY",
        )

    def test_the_policy_homes_harden_what_they_decode(self):
        text = (ROOT / "submodules/TelegramUIPreferences/Sources/MediaAutoDownloadSettings.swift").read_text()
        self.assertIn("func effectiveMediaAutoDownloadSettings(", text)
        self.assertIn("hardened(by:", text)
        for relative in ("submodules/TelegramPresentationData/Sources/PresentationData.swift",):
            self.assertIn(".hardened(by:", (ROOT / relative).read_text(), relative)
        self.assertIn("effectiveMediaAutoDownloadSettings(", (ROOT / "submodules/TelegramUI/Sources/SharedAccountContext.swift").read_text())

    def test_the_listed_files_still_exist(self):
        for relative in sorted(POLICY_HOME | set(DISPLAY_ONLY)):
            self.assertTrue((ROOT / relative).exists(), relative)

    def test_the_notification_service_keeps_media_out_under_lockdown(self):
        source = (ROOT / "Telegram/NotificationService/Sources/NotificationService.swift").read_text()
        self.assertIn("HardenedMediaPolicy.current.allowsNotificationMedia", source)
        build = (ROOT / "Telegram/NotificationService/BUILD").read_text()
        self.assertIn("//submodules/HardenedMedia", build)


if __name__ == "__main__":
    unittest.main()
