"""Calls never upload their stats JSON or full log on their own (security review H2, 2026-11-04).

The stats JSON holds the IP:port of the selected ICE candidates and the full log every gathered candidate. They stay
on the device for the user's own "send logs" screen. The Mac disabled the automatic upload; the iOS call code must not
bring it back.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
UPLOAD = re.compile(r"saveCallDebugLog|saveCompleteCallDebugLog")


class CallLogPrivacyTests(unittest.TestCase):
    def test_the_call_contexts_do_not_upload_logs(self):
        offenders = []
        for relative in ("submodules/TelegramVoip/Sources", "submodules/TelegramCallsUI/Sources"):
            for path in (ROOT / relative).rglob("*.swift"):
                for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                    if UPLOAD.search(line) and not line.lstrip().startswith("//"):
                        offenders.append(f"{path.relative_to(ROOT).as_posix()}:{number}")
        self.assertEqual(offenders, [])

    def test_call_logs_are_not_kept_longer_than_a_week(self):
        text = (ROOT / "submodules/TelegramVoip/Sources/OngoingCallContext.swift").read_text()
        self.assertIn("7.0 * 24.0 * 60.0 * 60.0", text)


if __name__ == "__main__":
    unittest.main()
