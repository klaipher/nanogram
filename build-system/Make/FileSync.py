"""Write generated build inputs without touching files whose content is unchanged.

Make.py regenerates build-input/configuration-repository on every run. Rewriting
identical files still changes their metadata, and Bazel (with --watchfs) then
reloads those packages and re-runs part of the analysis on every no-op build.
"""

import filecmp
import os
import shutil


def write_if_changed(path, content):
    """Writes `content` to `path` unless the file already holds exactly that."""
    if os.path.isfile(path):
        with open(path, 'r') as file:
            if file.read() == content:
                return False
    with open(path, 'w') as file:
        file.write(content)
    return True


def sync_directory(source_path, destination_path):
    """Makes `destination_path` a copy of the flat directory `source_path`.

    Files with identical content are left alone; changed and new files are copied
    and files missing from `source_path` are removed.
    """
    os.makedirs(destination_path, exist_ok=True)
    source_names = set(os.listdir(source_path))
    for name in os.listdir(destination_path):
        if name not in source_names:
            path = os.path.join(destination_path, name)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
    for name in source_names:
        source = os.path.join(source_path, name)
        destination = os.path.join(destination_path, name)
        if os.path.isfile(destination) and filecmp.cmp(source, destination, shallow=False):
            continue
        shutil.copyfile(source, destination)
