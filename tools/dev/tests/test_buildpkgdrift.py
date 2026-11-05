import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lint"))

import buildpkgdrift as drift  # noqa: E402

BUILD = '''
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# comment with "//submodules/Ignored"
package_group(name = "clients", packages = ["//submodules/NotADep"])

swift_library(
    name = "Postbox",
    module_name = "Postbox",
    srcs = glob([
        "Sources/**/*.swift",
    ], exclude = ["Sources/IOSOnly.swift", "Sources/Nested/Other.swift"]),
    deps = [
        "//submodules/Crc32:Crc32",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Utils/RangeSet",
        "@some_external//:thing",
        ":local",
    ],
)

swift_library(
    name = "PostboxTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":Postbox", "//submodules/OnlyForTests"],
)
'''

PACKAGE = '''// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "Postbox",
    dependencies: [
        .package(name: "Crc32", path: "../Crc32"),
    ],
    targets: [
        .target(
            name: "Postbox",
            dependencies: [.product(name: "Crc32", package: "Crc32", condition: nil),
                           .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                           .product(name: "DiskWriteAccounting", package: "DiskWriteAccounting", condition: nil)],
            path: "Sources",
            exclude: ["IOSOnly.swift", "BUILD", "Tests"]),
        .testTarget(
            name: "PostboxTests",
            dependencies: [.target(name: "Postbox"), .product(name: "TestOnly", package: "TestOnly")],
            path: "Tests"),
    ]
)
'''


class DescribeTests(unittest.TestCase):
    def test_build_reads_deps_and_excludes_of_the_main_library_only(self):
        described = drift.describe_build(BUILD, "Postbox")
        self.assertEqual(described.deps, {"Crc32", "SwiftSignalKit", "RangeSet"})
        self.assertEqual(described.excludes, {"IOSOnly.swift", "Other.swift"})

    def test_package_reads_the_first_non_test_target(self):
        described = drift.describe_package(PACKAGE)
        self.assertEqual(described.deps, {"Crc32", "SwiftSignalKit", "DiskWriteAccounting"})
        self.assertEqual(described.excludes, {"IOSOnly.swift"})

    def test_plain_string_and_target_dependencies(self):
        text = '.target(name: "M", dependencies: ["A", .target(name: "B"), .byName(name: "C")], path: "Sources")'
        self.assertEqual(drift.describe_package(text).deps, {"A", "B", "C"})

    def test_comments_are_ignored(self):
        text = '.target(name: "M", dependencies: [ // .product(name: "Gone", package: "Gone")\n .product(name: "Kept", package: "K")])'
        self.assertEqual(drift.describe_package(text).deps, {"Kept"})

    def test_label_to_module(self):
        self.assertEqual(drift.build_label_module("//submodules/Utils/RangeSet"), "RangeSet")
        self.assertEqual(drift.build_label_module("//a/b:C"), "C")
        self.assertIsNone(drift.build_label_module("@x//y:z"))
        self.assertIsNone(drift.build_label_module(":local"))

    def test_module_without_library_rule_is_none(self):
        self.assertIsNone(drift.describe_build('package_group(name = "x", packages = [])', "X"))
        self.assertIsNone(drift.describe_package("let package = Package(name: \"X\")"))

    def test_select_in_deps_collects_every_branch(self):
        text = 'swift_library(name = "M", deps = select({"//x:a": ["//submodules/A"], "//conditions:default": ["//submodules/B"]}))'
        self.assertEqual(drift.describe_build(text, "M").deps, {"A", "B"})

    def test_module_name_picks_the_matching_rule(self):
        text = 'swift_library(name = "Other", deps = ["//a/X"])\nswift_library(name = "M", deps = ["//a/Y"])'
        self.assertEqual(drift.describe_build(text, "M").deps, {"Y"})


class CompareTests(unittest.TestCase):
    def test_the_postbox_fixture_differs_in_both_directions(self):
        build = drift.describe_build(BUILD, "Postbox")
        package = drift.describe_package(PACKAGE)
        result = drift.compare("submodules/Postbox", build, package)
        self.assertEqual(result.deps_only_in_build, ["RangeSet"])
        self.assertEqual(result.deps_only_in_package, ["DiskWriteAccounting"])
        self.assertEqual(result.excludes_only_in_build, ["Other.swift"])
        self.assertEqual(result.excludes_only_in_package, [])
        self.assertFalse(result.empty)

    def test_identical_descriptions_are_empty(self):
        build = drift.Described({"A"}, {"x.swift"})
        self.assertTrue(drift.compare("m", build, drift.Described({"A"}, {"x.swift"})).empty)

    def test_the_missing_diskwriteaccounting_package_would_have_been_reported(self):
        build = drift.Described({"Postbox", "DiskWriteAccounting"})
        package = drift.Described({"Postbox"})
        self.assertEqual(drift.compare("submodules/TelegramCore", build, package).deps_only_in_build, ["DiskWriteAccounting"])

    def test_ios_only_sources_leaking_into_swiftpm_are_reported(self):
        build = drift.Described(set(), {"MediaPlayer.swift"})
        package = drift.Described(set(), set())
        self.assertEqual(drift.compare("m", build, package).excludes_only_in_build, ["MediaPlayer.swift"])


class ScanTests(unittest.TestCase):
    def make_root(self, tmp):
        root = Path(tmp)
        module = root / "submodules" / "Postbox"
        module.mkdir(parents=True)
        (module / "BUILD").write_text(BUILD)
        (module / "Package.swift").write_text(PACKAGE)
        only_build = root / "submodules" / "BuildOnly"
        only_build.mkdir()
        (only_build / "BUILD").write_text('swift_library(name = "BuildOnly", deps = [])')
        return root

    def test_only_modules_with_both_files_are_compared(self):
        with tempfile.TemporaryDirectory() as tmp:
            differences, skipped = drift.scan(self.make_root(tmp))
        self.assertEqual([d.module for d in differences], ["submodules/Postbox"])
        self.assertEqual(skipped, [])

    def test_report_lines_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_root(tmp)
            differences, skipped = drift.scan(root)
            lines = drift.render(differences, skipped)
            self.assertEqual(lines[0], "submodules/Postbox")
            self.assertIn("  dependencies only in BUILD: RangeSet", lines)
            self.assertIn("  dependencies only in Package.swift: DiskWriteAccounting", lines)
            self.assertTrue(lines[-1].startswith("build/package drift: 1 of 1 module(s)"))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(drift.main(["--root", str(root)]), 0)
                self.assertEqual(drift.main(["--root", str(root), "--strict"]), 1)
                self.assertEqual(drift.main(["--root", str(root), "--module", "Nope", "--strict"]), 0)

    def test_json_output_lists_only_differing_modules(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                drift.main(["--root", str(self.make_root(tmp)), "--json"])
        data = json.loads(out.getvalue())
        self.assertEqual(data[0]["module"], "submodules/Postbox")

    def test_this_repository_can_be_scanned(self):
        root = Path(__file__).resolve().parents[3]
        differences, _ = drift.scan(root)
        self.assertGreater(len(differences), 20)
        names = {Path(d.module).name for d in differences}
        self.assertIn("Postbox", names)


if __name__ == "__main__":
    unittest.main()
