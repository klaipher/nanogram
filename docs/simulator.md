# Simulator: updating the app, driving the UI, visual checks

### Updating the running simulator after a rebuild (whole-`.app` copy)

`tools/dev/tg run` does all of this for the default simulator build: `tg build` makes `bazel-bin/Telegram/Telegram_archive-root/Payload/Nanogram.app` directly (tree artifact, no `.ipa`), and `tg run` clones it to a writable staging copy, replaces the installed bundle in place (or installs it) on the test simulator and launches it. The recipe below is for plain `Make.py` builds, which still produce an `.ipa`.

`simctl install` will NOT replace an already-installed app when the build number is unchanged (installd keeps a hard-link cache), so a rebuilt binary silently doesn't take effect. **Preferred fix: copy the whole freshly-built `.app` over the installed bundle in place.** This is more robust than swapping only the `Frameworks/TelegramUIFramework` binary (no risk of app↔framework version skew), and it preserves the account/login because the **data container is a separate path** (`.../data/Containers/Data/Application/<uuid>/`, keyed by bundle id) — only the **bundle** container is replaced, and the install-DB entry stays valid since the path + bundle id are unchanged.

```sh
K3=4483DD69-685A-4FE1-89BE-65F992C271F2   # iPhone 18 Pro K3 (use the dedicated K-sims, not the shared default)
# The K-sims were RECREATED by the Xcode 27 update (2026-09-15), which removed every simulator:
# they are iPhone 18 Pro now, on new UDIDs. K1=03A7DA9C-1832-49B8-9858-2F54F2FB5A04, K2=E643A78E-DB62-4DA4-9F54-BD0836F434AF.
BUNDLE=ph.telegra.Telegraph
# Fresh build output. Go through `bazel-bin`, which bazel repoints at
# the LAST BUILD's configuration. Do NOT `find` under `bazel-out`: it keeps one directory per
# configuration you have ever built, so `… | head -1` can hand you a stale *device* archive. That copies
# fine and then refuses to launch ("request was denied by service delegate (SBMainWorkspace)"), which
# reads like a crash rather than an arch mismatch — and `lipo -archs` does not disambiguate, since device
# and simulator arm64 slices both report plain `arm64`.
# SOURCE THE .ipa, NOT `Telegram_archive-root/`. The archive-root directory is only rewritten when
# the packaging step actually re-runs; on a cache-hit incremental build it is left behind holding a
# PREVIOUS build's binaries, and nothing about it looks stale (see the note below). The .ipa is
# rewritten every build and carries a real mtime.
STAGE=$(mktemp -d)
unzip -q -o bazel-bin/Telegram/Telegram.ipa -d "$STAGE"
SRC="$STAGE/Payload/Nanogram.app"
DEST="$(xcrun simctl get_app_container "$K3" "$BUNDLE" app)"   # installed bundle path
# GUARD before the destructive rm: never rm the installed app unless SRC actually resolved,
# or a failed cp leaves the sim with NO app installed (relaunch then fails).
[ -x "$SRC/Telegram" ] || { echo "no fresh bundle at SRC=$SRC — aborting"; exit 1; }
xcrun simctl terminate "$K3" "$BUNDLE" 2>/dev/null            # terminate before replacing the running binary
rm -rf "$DEST" && cp -Rp "$SRC" "$DEST"                        # replace bundle in place; data container untouched
xcrun simctl launch "$K3" "$BUNDLE"
```

The sim ignores code signing, so the unsigned bundle runs fine.

**`Telegram_archive-root/` goes stale silently — do not install from it.** It is written by the
Make.py wrapper's post-build packaging, which only re-runs when the packaging action itself is not a
cache hit. After an incremental build (`Build completed successfully, 21 total actions`, ~30s) the
directory is simply left as it was, still holding a PREVIOUS build's binaries, while
`bazel-bin/Telegram/Telegram.ipa` *is* rewritten. Demonstrated 2026-08-20: one build produced an
archive-root framework and an .ipa framework with different md5s, the archive-root one still
containing symbols from source that had already been reverted.

There is no cheap way to eyeball the staleness, which is what makes it dangerous:
- **mtime cannot detect it.** Bazel stamps a reproducible `Jan 1 1980` on everything under
  archive-root, so the stale copy and a fresh one look identical.
- The stale bundle launches and behaves normally — it is simply *older code*. The failure mode is
  "I am debugging behaviour that is not in the source I am reading", which can burn an entire
  investigation before anyone suspects the bundle. It did exactly that once already.

So the recipe above unzips the `.ipa` instead. If you ever do copy from archive-root, verify first:
`md5 -q .../Telegram_archive-root/Payload/Nanogram.app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework`
against the same path unzipped out of the `.ipa`, and treat a mismatch as stale.

(The older framework-only `cp` of `TelegramUIFramework` still works and is faster, but prefer the
whole-`.app` copy to avoid version skew.)

### Driving the simulator UI: use the Xcode MCP server

**XcodeBuildMCP is configured for this project** (`~/.claude.json` → `projects["…/telegram-ios"].mcpServers.XcodeBuildMCP`, run as `npx -y xcodebuildmcp@latest mcp`). Its tools appear as `mcp__XcodeBuildMCP__*` and are the way to **interact with** a running simulator — screenshots, `describe_ui` accessibility dumps, taps/swipes/typing, log capture. Reach for it whenever a change needs verification that a build alone can't give: flipping a Debug Settings flag, opening a chat, scrolling a list, checking that something rendered.

Do **not** fall back to `cliclick` / `osascript` / `screencapture -R` for this. Those need macOS Accessibility and Screen Recording privileges that the terminal running Claude Code does not have (`cliclick` reports "Accessibility privileges not enabled"; `screencapture -R` fails with "could not create image from rect"), and with several K-sims booted at once there is no way to identify the right Simulator window anyway. `xcrun simctl io <udid> screenshot` **does** work without extra privileges and is fine for a passive look, but it cannot drive anything.

If the `mcp__XcodeBuildMCP__*` tools are absent from a session's tool list (it has happened — the server is configured but its tools weren't exposed), say so and hand the interactive checks to the user rather than attempting the privilege-blocked fallbacks.

### Visual features and animations: verify from recorded frames

Any visual change, and always an animated one, is verified by recording the simulator and reading its frames, not by
a green build: [`AGENTS.md`](AGENTS.md), "Visual features and animations" (`simctl io recordVideo`, then
`tools/animation_sheet.py` for labelled frame sheets, per-frame numbers and per-element tracks in points).
