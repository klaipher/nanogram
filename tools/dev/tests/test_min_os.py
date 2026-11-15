"""The iOS minimum lives in Telegram/BUILD; every target and script-built library must agree with it."""
import importlib.util
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("set_min_os", ROOT / "tools/dev/set-min-os.py")
set_min_os = importlib.util.module_from_spec(spec)
spec.loader.exec_module(set_min_os)

IOS_ONLY = {
    "submodules/ffmpeg/Sources/FFMpeg/build-ffmpeg-bazel.sh": r'^DEPLOYMENT_TARGET="([\d.]+)"',
    "third-party/opus/build-opus-bazel.sh": r'^MINIOSVERSION="([\d.]+)"',
}
IOS_ARMS = {
    "third-party/webp/build-webp-bazel.sh": r"miphoneos-version-min=([\d.]+) -funwind|ios([\d.]+)-simulator",
    "third-party/libjpeg-turbo/build-libjpeg-turbo-bazel.sh": r"miphoneos-version-min=([\d.]+)|ios([\d.]+)-simulator",
    "third-party/td/build-td-bazel.sh": r"IOS_DEPLOYMENT_TARGET=([\d.]+)|ios([\d.]+)(?:-simulator)? -m",
    "third-party/dav1d/arm64-iPhoneSimulator.meson": r"simulator-version-min=([\d.]+)",
    "third-party/dav1d/build-dav1d-bazel.sh": r"miphoneos-version-min=([\d.]+)",
    "third-party/libvpx/build-libvpx-bazel.sh": r"-miphoneos-version-min=([\d.]+)|--target=arm64-apple-ios([\d.]+)-simulator",
}


class MinOsTests(unittest.TestCase):
    def test_no_build_file_drifts_from_telegram_build(self):
        version, drift = set_min_os.rewrite(ROOT, check=True)
        self.assertEqual(drift, [], f"run tools/dev/set-min-os.py (expected {version})")

    def test_script_built_libraries_use_the_app_floor(self):
        version = set_min_os.source_version(ROOT)
        for rel, pattern in {**IOS_ONLY, **IOS_ARMS}.items():
            found = [next(g for g in m.groups() if g) for m in re.finditer(pattern, (ROOT / rel).read_text(), re.M)]
            self.assertTrue(found, rel)
            self.assertEqual(set(found), {version}, rel)

    def test_mac_arms_stay_at_macos_14(self):
        for rel in ["third-party/webp/build-webp-bazel.sh", "third-party/td/build-td-bazel.sh", "third-party/dav1d/build-dav1d-bazel.sh"]:
            self.assertIn("macosx-version-min=14.0", (ROOT / rel).read_text(), rel)

    # SHARED-APPLE-CPU-1: the 26.0 floor gives inline LSE atomics, so outline atomics are not needed (and do not link on Darwin).
    @unittest.skipUnless(shutil.which("xcrun"), "xcrun not available")
    def test_ios_floor_compiles_inline_lse_atomics(self):
        res = subprocess.run(["xcrun", "-sdk", "iphoneos", "clang", "-target", f"arm64-apple-ios{set_min_os.source_version(ROOT)}", "-dM", "-E", "-x", "c", "/dev/null"],
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
            cmd = ["xcrun", "-sdk", "iphoneos", "clang++", "-target", f"arm64-apple-ios{set_min_os.source_version(ROOT)}", "-O2", "-S", str(src), "-o", "-"]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                self.skipTest("iphoneos SDK not installed")
            self.assertIn("ldadd", res.stdout)
            self.assertNotIn("___aarch64_", res.stdout)
            self.assertNotIn("ldaxr", res.stdout)


if __name__ == "__main__":
    unittest.main()
