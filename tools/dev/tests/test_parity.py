"""The parity gate and its tests live in shared/ (klaipher/nanogram-deps, tests/test_parity.py). These tests cover what is
specific to this repository: its docs/mac-core-paths.txt and the thin wrappers around shared/."""
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SHARED = ROOT / "shared"
sys.path.insert(0, str(SHARED))

import parity  # noqa: E402

needs_shared = unittest.skipUnless((SHARED / "parity.py").is_file(), "shared/ submodule not checked out")


@needs_shared
class RepositoryConfigTests(unittest.TestCase):
    def test_repository_file_parses(self):
        config = parity.load_config(ROOT)
        self.assertTrue(config.core_roots and config.shares and config.pins)
        self.assertTrue(all(a.reason for a in config.allows))

    def test_repository_mirrors_name_the_vp9_copies(self):
        config = parity.load_config(ROOT)
        names = {m.ios.rsplit("/", 1)[-1] for m in config.mirrors}
        self.assertEqual(names, {"VP9HardwareDecoder.swift", "WebMStickerDemuxer.swift"})
        for mirror in config.mirrors:
            self.assertEqual(mirror.ios.rsplit("/", 1)[-1], mirror.mac.rsplit("/", 1)[-1])

    def test_every_lib_line_is_known_to_the_manifest(self):
        config = parity.load_config(ROOT)
        known = set(json.loads((SHARED / "shared-libraries.json").read_text())["libraries"])
        self.assertTrue(config.libs)
        self.assertEqual([lib.name for lib in config.libs if lib.name not in known], [])

    def test_no_vendored_policy_or_doc_copies_remain(self):
        for path in ("tools/dev/cachegc/cache-policy.json", "docs/feature-parity.md", "docs/development-pipeline.md"):
            self.assertFalse((ROOT / path).exists(), path)


@needs_shared
class WrapperTests(unittest.TestCase):
    def run_wrapper(self, *args):
        return subprocess.run([sys.executable, str(ROOT / args[0]), *args[1:]], capture_output=True, text=True, check=False)

    def test_parity_wrapper_forwards_to_shared(self):
        result = self.run_wrapper("tools/dev/parity/parity.py", "check", "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--android-repo", result.stdout)

    def test_check_shared_wrapper_defaults_to_the_ios_side(self):
        result = self.run_wrapper("tools/dev/native/check_shared.py", "--ref", "HEAD")
        self.assertIn("== ios:", result.stdout)
        self.assertNotIn("error:", result.stdout)

    def test_wrappers_hold_no_copy_of_the_tools(self):
        for path in ("tools/dev/parity/parity.py", "tools/dev/native/check_shared.py"):
            self.assertLess(len((ROOT / path).read_text().splitlines()), 40, path)


if __name__ == "__main__":
    unittest.main()
