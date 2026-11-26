"""The emoji and sticker keyboard contents are built on their own serial queue, never inside a Postbox transaction.

`Postbox.itemCollectionsView` and `combinedView` hand their first value to the subscriber inside the transaction, and a
`combineLatest` without a queue runs its `map` on the thread of whichever input arrives last. The big map in
`emojiInputData` and `stickerInputData` (every item of every pack) therefore ran inside a Postbox transaction on every
chat open: tester critical logs of 202611232311 show a single-peer read taking ~33 ms ~430 times in three days, always
right after the emoji keyboard's featured-pack read. `combineLatest(queue:)` hops every input to that queue first, so the
map and its unsynchronized reuse caches run there, serially and in order.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "submodules/TelegramUI/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift"
BUILDERS = ("emojiInputData", "stickerInputData")
COMPONENT_MAP = re.compile(r"\A\s*\|>\s*map\s*\{[^{}]*->\s*EmojiPagerContentComponent\s+in\b")


def function_body(text, name):
    start = text.find(f"static func {name}(")
    if start < 0:
        raise AssertionError(f"{name} not found in {SOURCE.name}")
    # The next member of the extension; nested types inside the function declare their own `static func ==`.
    end = re.compile(r"^    (?:\w+ )*static func ", re.MULTILINE).search(text, start + 1)
    return text[start:] if end is None else text[start:end.start()]


def call_arguments(text, open_paren):
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:index], index + 1
    raise AssertionError("unbalanced combineLatest call")


def component_builds(body):
    """Each combineLatest whose result goes straight into the map that builds the EmojiPagerContentComponent."""
    builds = []
    for match in re.finditer(r"\bcombineLatest\(", body):
        arguments, after = call_arguments(body, match.end() - 1)
        if COMPONENT_MAP.match(body[after:]):
            builds.append(arguments)
    return builds


def queue_argument(arguments):
    match = re.match(r"\s*queue:\s*([A-Za-z_][A-Za-z0-9_]*)\s*,", arguments)
    return match.group(1) if match else None


class KeyboardDataBuildQueueTests(unittest.TestCase):
    def test_component_map_runs_on_a_dedicated_serial_queue(self):
        text = SOURCE.read_text()
        for name in BUILDERS:
            with self.subTest(builder=name):
                body = function_body(text, name)
                builds = component_builds(body)
                self.assertEqual(len(builds), 1, f"{name}: expected one combineLatest feeding the component map")
                queue = queue_argument(builds[0])
                self.assertIsNotNone(queue, f"{name}: the component map's combineLatest has no queue:, so it runs inside a Postbox transaction")
                self.assertRegex(
                    body,
                    rf"\blet\s+{queue}\s*=\s*Queue\(name:",
                    f"{name}: {queue} must be a serial Queue(name:) created for this build, not the main or a shared queue",
                )

    def test_guard_sees_a_queueless_build(self):
        body = "static func emojiInputData() {\n    return combineLatest(\n        a,\n        b\n    )\n    |> map { a, b -> EmojiPagerContentComponent in\n    }\n}\n"
        builds = component_builds(body)
        self.assertEqual(len(builds), 1)
        self.assertIsNone(queue_argument(builds[0]))


if __name__ == "__main__":
    unittest.main()
