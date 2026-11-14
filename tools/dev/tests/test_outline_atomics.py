"""SHARED-APPLE-CPU-1: the iOS floor gives inline LSE atomics; outline atomics stay withdrawn (helper symbol names do not link at older targets)."""
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


def ios_floor():
    import re
    return re.search(r'^minimum_os_version = "([0-9.]+)"', (ROOT / "Telegram/BUILD").read_text(), re.M).group(1)


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
    def test_ios_floor_compiles_inline_lse_atomics(self):
        res = subprocess.run(["xcrun", "-sdk", "iphoneos", "clang", "-target", f"arm64-apple-ios{ios_floor()}", "-dM", "-E", "-x", "c", "/dev/null"],
                             capture_output=True, text=True)
        if res.returncode != 0:
            self.skipTest("iphoneos SDK not installed")
        self.assertRegex(res.stdout, r"#define __ARM_FEATURE_ATOMICS 1")
        self.assertNotIn("__ARM_FEATURE_DOTPROD", res.stdout, "apple-a13 would break A12 iPads")

    @unittest.skipUnless(shutil.which("xcrun"), "xcrun not available")
    def test_atomic_rmw_is_inline_lse_without_helper_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "a.cpp"
            src.write_text("#include <atomic>\nstd::atomic<int> g;\nint f() { return g.fetch_add(1); }\n")
            cmd = ["xcrun", "-sdk", "iphoneos", "clang++", "-target", f"arm64-apple-ios{ios_floor()}", "-O2", "-S", str(src), "-o", "-"]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                self.skipTest("iphoneos SDK not installed")
            self.assertIn("ldadd", res.stdout)
            self.assertNotIn("___aarch64_", res.stdout)
            self.assertNotIn("ldaxr", res.stdout)


if __name__ == "__main__":
    unittest.main()
