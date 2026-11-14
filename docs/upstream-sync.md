# Upstream sync dry run

`tg upstream-sync --tag <upstream tag>` answers, before any merge: which files conflict (grouped by area), and which pinned dependencies upstream bumped (tgcalls, webrtc, tlottie, mtproto-engine, ...) and whether upstream's new commits are already in our fork branches.

This repository starts at its own root, so there is no upstream ancestry to merge from. The tool works in a scratch bare repository (it borrows this repo's objects through alternates): it fetches the tag shallowly, makes a synthetic commit of the release we are based on (config `base_commit`, whose tree equals the imported release) and one of the new tag, and runs `git merge-tree --write-tree --merge-base=<old> main <new>` - a real three-way merge in memory. Nothing is checked out, pushed or fetched into this repository.

- Config: `tools/dev/upstream-sync/upstream-sync.json` (base commit and label, branch, areas, pins with upstream and fork URLs).
- Moved libraries: `moved_libraries` in the config lists the paths Telegram-iOS ships as vendored source that we replaced by a submodule of a fork (FFmpeg, openh264, rnnoise, libprisma, sqlcipher-amalgamation, libyuv, boringssl, quickjs, widget-sandbox, twidget, the webrtc third_party dirs) or by an official pin (ogg, opus, opusfile, libwebp, boost_regex, wamr). The report names every library whose files upstream changed and the fork branch to patch (or the pin to bump), so an upstream fix to a moved library is ported by hand instead of vanishing in a modify/delete conflict. Add a library here whenever one more path moves out of the tree.
- Options: `--ours <branch>`, `--offline` (skip the fork checks), `--json`, `--fail-on-conflict`.
- After a release is merged, move `base_commit` to the commit that holds the new release tree.
- `tg setup` turns on `rerere`, so a conflict resolved once (DebugController, branding) is replayed on the next merge.
- Tests: `tools/dev/tests/test_upstream_sync.py` (local repositories only).
