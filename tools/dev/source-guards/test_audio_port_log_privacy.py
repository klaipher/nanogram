"""Audio route log lines carry no device names.

ManagedAudioSession lines go to the text log and to the always-on critical log (AppDelegate sends them through both
Logger.shared.log and shortLog), and the report does not mask critical logs. A port's name is the one the user gave the
device, often "<first name>'s AirPods Pro", so the logs describe a port by its type and a hash of its uid instead
(audioPortLogLabel). The name is still read for the route picker, which shows it.

Output modes are put into log lines whole ("setup \\(outputMode)"), and Swift's default description of a value lists every
stored field, so AudioSessionPort, AudioSessionOutput and AudioSessionOutputMode describe themselves; the port by its
kind and uid tag only. That behaviour is pinned by AudioPortLogLabelTests; these checks keep the text from drifting.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
AUDIO = ROOT / "submodules/TelegramAudio"
SESSION = AUDIO / "Sources/ManagedAudioSession.swift"

LOG_CALL = re.compile(r"managedAudioSessionLog\(|Logger\.shared\.(?:log|shortLog)\(")
LOG_HELPERS = ("describeAudioPort", "audioInputStateDescription")
# Values that hold a device's name or uid: an AVAudioSessionPortDescription, an AudioSessionRoutePort, an AudioSessionPort.
NAME_OR_UID = re.compile(r"\bportName\b|\.name\b|\.uid\b")
DESCRIBED_TYPES = ("AudioSessionPort", "AudioSessionOutput", "AudioSessionOutputMode")


def swift_sources():
    return sorted(p for d in ("Sources", "Macos") for p in (AUDIO / d).rglob("*.swift"))


def balanced(text, start, opening, closing):
    """The text from `start` (just after an opening bracket) to its matching closing bracket."""
    depth = 1
    i = start
    while i < len(text) and depth:
        if text[i] == opening:
            depth += 1
        elif text[i] == closing:
            depth -= 1
        i += 1
    return text[start:i - 1]


def log_arguments(text):
    for match in LOG_CALL.finditer(text):
        yield balanced(text, match.end(), "(", ")")


def extension_body(text, type_name, protocol):
    match = re.search(r"extension\s+" + type_name + r"\s*:[^{]*\b" + protocol + r"\b[^{]*\{", text)
    if match is None:
        return None
    return balanced(text, match.end(), "{", "}")


def function_body(text, name):
    match = re.search(r"func\s+" + name + r"\b[^{]*\{", text)
    if match is None:
        return None
    return balanced(text, match.end(), "{", "}")


class AudioPortLogPrivacyTests(unittest.TestCase):
    def test_no_log_call_carries_a_port_name_or_uid(self):
        for path in swift_sources():
            for argument in log_arguments(path.read_text()):
                self.assertIsNone(NAME_OR_UID.search(argument), f"{path.relative_to(ROOT)}: {argument[:120]}")

    def test_the_output_types_describe_themselves(self):
        text = SESSION.read_text()
        for name in DESCRIBED_TYPES:
            body = extension_body(text, name, "CustomStringConvertible")
            self.assertIsNotNone(body, f"{name} has no CustomStringConvertible extension: the default lists every field")
            self.assertIn("var description", body, name)

    def test_the_port_description_shows_only_the_kind_and_the_uid_tag(self):
        body = extension_body(SESSION.read_text(), "AudioSessionPort", "CustomStringConvertible")
        self.assertIsNotNone(body)
        for protocol in ("CustomDebugStringConvertible", "CustomReflectable"):
            self.assertIsNotNone(extension_body(SESSION.read_text(), "AudioSessionPort", protocol), protocol)
        self.assertNotIn(".name", body)
        # The uid is read only to hash it.
        self.assertIn("audioPortLogTag(uid: self.uid)", body)
        self.assertEqual(body.count("self.uid"), body.count("audioPortLogTag(uid: self.uid)"), body)

    def test_the_port_description_helpers_do_not_read_the_name(self):
        text = SESSION.read_text()
        for name in LOG_HELPERS:
            body = function_body(text, name)
            self.assertIsNotNone(body, f"{name} not found in {SESSION.relative_to(ROOT)}")
            self.assertNotIn("portName", body, name)
            self.assertNotIn(".name", body, name)

    def test_the_name_is_read_only_for_the_route_picker(self):
        for path in swift_sources():
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                if "portName" in line:
                    self.assertIn("name: description.portName", line, f"{path.relative_to(ROOT)}:{number}")

    def test_the_route_line_is_written_only_when_it_changes(self):
        body = function_body(SESSION.read_text(), "updateCurrentAudioRouteInfo")
        self.assertIsNotNone(body)
        self.assertIn("routeLogDeduplicator.shouldLog(", body)

    def test_the_helpers_find_a_name_in_a_log_call(self):
        sample = 'managedAudioSessionLog("x \\(f(port.portName)) y")\nfunc describeAudioPort(_ p: P) -> String {\n    return "\\(p.portName)"\n}\n'
        self.assertIn("portName", next(log_arguments(sample)))
        self.assertIn("portName", function_body(sample, "describeAudioPort"))
        for leak in ('managedAudioSessionLog("\\(port.name)")', 'managedAudioSessionLog("\\(input.uid)")'):
            self.assertIsNotNone(NAME_OR_UID.search(next(log_arguments(leak))), leak)
        self.assertIsNone(NAME_OR_UID.search(next(log_arguments('managedAudioSessionLog("\\(port.portType.rawValue) \\(outputMode)")'))))
        extension = "extension AudioSessionPort: CustomStringConvertible, CustomReflectable {\n    var description: String { x }\n}\n"
        self.assertIn("var description", extension_body(extension, "AudioSessionPort", "CustomStringConvertible"))
        self.assertIsNotNone(extension_body(extension, "AudioSessionPort", "CustomReflectable"))
        self.assertIsNone(extension_body(extension, "AudioSessionOutput", "CustomStringConvertible"))


if __name__ == "__main__":
    unittest.main()
