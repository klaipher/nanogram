"""Call logs kept on the device are removed after a week at most.

The automatic upload of the call stats JSON and full log (phone.saveCallDebug) is back as in official Telegram (owner
decision, 2026-11-05), so the former guard against it is gone. Only the retention of local logs is still checked.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class CallLogPrivacyTests(unittest.TestCase):
    def test_call_logs_are_not_kept_longer_than_a_week(self):
        text = (ROOT / "submodules/TelegramVoip/Sources/OngoingCallContext.swift").read_text()
        self.assertIn("7.0 * 24.0 * 60.0 * 60.0", text)


if __name__ == "__main__":
    unittest.main()
