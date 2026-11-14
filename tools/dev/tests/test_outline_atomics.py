"""SHARED-APPLE-CPU-1: outline atomics are blocked on iOS device (helper symbol names do not link). Pure Python plus an optional xcrun link probe."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = [
    "third-party/webp/build-webp-bazel.sh",
    "third-party/libjpeg-turbo/build-libjpeg-turbo-bazel.sh",
    "third-party/td/build-td-bazel.sh",
    "third-party/opus/build-opus-bazel.sh",
    "submodules/ffmpeg/Sources/FFMpeg/build-ffmpeg-bazel.sh",
]


class OutlineAtomicsBlockedTests(unittest.TestCase):
    def test_config_is_withdrawn_from_bazelrc(self):
        rc = (ROOT / ".bazelrc").read_text()
        self.assertNotIn("build:outline_atomics", rc)
        self.assertNotRegex(rc, r"(?m)^build .*-moutline-atomics")
        self.assertIn("BLOCKED", rc)

    def test_native_scripts_do_not_add_the_flag(self):
        for rel in SCRIPTS:
            text = (ROOT / rel).read_text()
            self.assertNotIn("-moutline-atomics", text, rel)
            self.assertNotIn("NANOGRAM_OUTLINE_ATOMICS", text, rel)

    @unittest.skipUnless(shutil.which("xcrun"), "xcrun not available")
    def test_ios_device_link_with_outline_atomics_still_fails(self):
        """Link smoke test: documents why the config is blocked. When this fails the link works: re-evaluate SHARED-APPLE-CPU-1."""
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "a.cpp"
            src.write_text("#include <atomic>\nstd::atomic<int> g;\nint f() { return g.fetch_add(1); }\n")
            cmd = ["xcrun", "-sdk", "iphoneos", "clang++", "-target", "arm64-apple-ios15.0", "-O2",
                   "-moutline-atomics", "-dynamiclib", str(src), "-o", str(Path(tmp) / "a.dylib")]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if "SDK" in res.stderr and "cannot be located" in res.stderr:
                self.skipTest("iphoneos SDK not installed")
            self.assertNotEqual(res.returncode, 0, "outline atomics now link on device; the config can be restored with a proof build")
            self.assertIn("___aarch64_", res.stderr)


if __name__ == "__main__":
    unittest.main()
