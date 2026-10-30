"""Tests for FileSync.

Run: python3 -m unittest discover -s build-system/Make/tests -v
"""

import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

from FileSync import write_if_changed, sync_directory  # noqa: E402


def write(path, content):
    with open(path, 'w') as file:
        file.write(content)


def read(path):
    with open(path) as file:
        return file.read()


class FileSyncTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def test_write_if_changed_creates_and_skips_identical_content(self):
        path = os.path.join(self.root, 'a.bzl')
        self.assertTrue(write_if_changed(path, 'x = 1\n'))
        inode = os.stat(path).st_ino
        mtime = os.stat(path).st_mtime_ns
        self.assertFalse(write_if_changed(path, 'x = 1\n'))
        self.assertEqual((os.stat(path).st_ino, os.stat(path).st_mtime_ns), (inode, mtime))
        self.assertTrue(write_if_changed(path, 'x = 2\n'))
        self.assertEqual(read(path), 'x = 2\n')

    def test_sync_directory_copies_changes_removes_extras_keeps_identical(self):
        source = os.path.join(self.root, 'source')
        destination = os.path.join(self.root, 'destination')
        os.makedirs(source)
        os.makedirs(os.path.join(destination, 'stale_dir'))
        write(os.path.join(source, 'same'), 'same')
        write(os.path.join(source, 'changed'), 'new')
        write(os.path.join(source, 'added'), 'added')
        write(os.path.join(destination, 'same'), 'same')
        write(os.path.join(destination, 'changed'), 'old')
        write(os.path.join(destination, 'stale'), 'stale')
        same_stat = os.stat(os.path.join(destination, 'same'))

        sync_directory(source, destination)

        self.assertEqual(sorted(os.listdir(destination)), ['added', 'changed', 'same'])
        self.assertEqual(read(os.path.join(destination, 'changed')), 'new')
        self.assertEqual(read(os.path.join(destination, 'added')), 'added')
        after = os.stat(os.path.join(destination, 'same'))
        self.assertEqual((after.st_ino, after.st_mtime_ns), (same_stat.st_ino, same_stat.st_mtime_ns))

    def test_sync_directory_creates_destination(self):
        source = os.path.join(self.root, 'source')
        os.makedirs(source)
        write(os.path.join(source, 'f'), 'f')
        destination = os.path.join(self.root, 'new', 'destination')
        sync_directory(source, destination)
        self.assertEqual(read(os.path.join(destination, 'f')), 'f')


if __name__ == '__main__':
    unittest.main()
