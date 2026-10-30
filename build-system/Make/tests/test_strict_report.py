"""Tests for StrictReport.

Run: python3 -m unittest discover -s build-system/Make/tests -v
"""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

from StrictReport import count_by_package, package_of, parse_log  # noqa: E402


class StrictReportTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        for package in ('submodules/A', 'submodules/A/Nested'):
            os.makedirs(os.path.join(self.root, package, 'Sources'))
            open(os.path.join(self.root, package, 'BUILD'), 'w').close()

    def test_parse_log_dedupes_and_collects_failed_modules(self):
        lines = [
            "submodules/A/Sources/x.swift:3:5: warning: main actor-isolated property 'p' can not be referenced\n",
            "submodules/A/Sources/x.swift:3:5: warning: main actor-isolated property 'p' can not be referenced\n",
            "  |    `- warning: main actor-isolated property 'p' can not be referenced\n",
            "submodules/A/Sources/x.swift:9:1: error: type 'T' does not conform to protocol 'P'\n",
            "ERROR: /w/submodules/A/BUILD:3:14: Compiling Swift module //submodules/A:A failed: (Exit 1)\n",
            "ERROR: /w/submodules/A/BUILD:3:14: Compiling Swift module //submodules/A:A failed: (Exit 1)\n",
        ]
        diagnostics, failed = parse_log(lines)
        self.assertEqual(diagnostics, {
            ('submodules/A/Sources/x.swift', 3, 5, 'warning'),
            ('submodules/A/Sources/x.swift', 9, 1, 'error'),
        })
        self.assertEqual(failed, ['//submodules/A:A'])

    def test_files_belong_to_the_nearest_package(self):
        self.assertEqual(package_of(self.root, 'submodules/A/Sources/x.swift'), 'submodules/A')
        self.assertEqual(package_of(self.root, 'submodules/A/Nested/Sources/y.swift'), 'submodules/A/Nested')
        absolute = os.path.join(self.root, 'submodules/A/Sources/x.swift')
        self.assertEqual(package_of(self.root, absolute), 'submodules/A')
        self.assertIsNone(package_of(self.root, '/elsewhere/z.swift'))

    def test_count_by_package(self):
        counts = count_by_package(self.root, {
            ('submodules/A/Sources/x.swift', 1, 1, 'warning'),
            ('submodules/A/Sources/x.swift', 2, 1, 'warning'),
            ('submodules/A/Nested/Sources/y.swift', 1, 1, 'warning'),
            ('/elsewhere/z.swift', 1, 1, 'warning'),
        })
        self.assertEqual(dict(counts), {'submodules/A': 2, 'submodules/A/Nested': 1})


if __name__ == '__main__':
    unittest.main()
