"""SHARED-APPLE-CPU-1: the opt-in outline-atomics config and the native-library scripts that honour it. Pure Python, no build."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = [
    "third-party/webp/build-webp-bazel.sh",
    "third-party/libjpeg-turbo/build-libjpeg-turbo-bazel.sh",
    "third-party/libjxl/build-libjxl-bazel.sh",
    "third-party/td/build-td-bazel.sh",
    "third-party/opus/build-opus-bazel.sh",
    "submodules/ffmpeg/Sources/FFMpeg/build-ffmpeg-bazel.sh",
]
ENV = "NANOGRAM_OUTLINE_ATOMICS"


class OutlineAtomicsTests(unittest.TestCase):
    def test_config_is_opt_in_and_sets_copt_and_action_env(self):
        rc = (ROOT / ".bazelrc").read_text()
        self.assertIn("build:outline_atomics --copt=-moutline-atomics", rc)
        self.assertIn("build:outline_atomics --action_env=%s=1" % ENV, rc)
        self.assertNotRegex(rc, r"(?m)^build --copt=-moutline-atomics")
        self.assertNotRegex(rc, r"(?m)^build --action_env=%s" % ENV)

    def test_every_native_script_gates_the_flag_on_the_env_var(self):
        for rel in SCRIPTS:
            text = (ROOT / rel).read_text()
            self.assertIn('"${%s:-0}" = "1"' % ENV, text, rel)
            self.assertIn("-moutline-atomics", text, rel)

    def test_flag_is_never_added_on_the_x86_64_or_macos_branches(self):
        for rel in SCRIPTS[:4]:
            lines = (ROOT / rel).read_text().splitlines()
            for i, line in enumerate(lines):
                if "-moutline-atomics" in line:
                    prev = next(l for l in reversed(lines[:i]) if "export CFLAGS=" in l)
                    self.assertIn("-arch arm64", prev, rel)
                    self.assertNotIn("macosx", prev, rel)

    def test_opus_and_ffmpeg_restrict_to_ios_arm64(self):
        for rel in SCRIPTS[4:]:
            text = (ROOT / rel).read_text()
            block = re.search(r'if \[ "\$\{%s:-0\}" = "1" \] && \{(.*?)\}; then' % ENV, text, re.S)
            self.assertIsNotNone(block, rel)
            self.assertIn('"sim_arm64"', block.group(1))
            self.assertNotIn("macos", block.group(1))


if __name__ == "__main__":
    unittest.main()
