# Build and test

## Build

The app is built using Bazel via the `Make.py` wrapper. There is no selective per-module build — the only supported invocation builds the full `Telegram/Telegram` target.

**Command:**

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion \
 --cacheDir ~/telegram-bazel-cache \
 build \
 --configurationPath build-system/appstore-configuration.json \
 --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git \
 --gitCodesigningType development --gitCodesigningUseCurrent --buildNumber=1 --configuration=debug_sim_arm64
```

Add `--continueOnError` after `build` (forwards to bazel's `--keep_going`) when verifying changes that may surface errors in many files at once — it lets the full set of errors land in one pass instead of stopping at the first failing target.

The build needs `TELEGRAM_CODESIGNING_GIT_PASSWORD` in the environment. It is set in `~/.zshrc` but Claude Code's bash tool does NOT source shell config by default. Prefix build commands with `source ~/.zshrc 2>/dev/null;` to pick it up.

**Platform hardening (2026-11-04).** (1) Every `ios_extension` in `Telegram/BUILD` has explicit entitlements built by `extension_entitlements` in `Telegram/entitlements.bzl`: the app group and the extension's own `application-identifier`, nothing else, so no extension inherits the provisioning profile's `TEAM.*` keychain group any more (the passcode shared group is the app group, which stays reachable; the wallet's private group is the main app's and now cannot be read by an extension at all). Notification Service adds only the filtering entitlement (when `notification_filtering_enabled`), which its profile carries; communication notifications stay on the main app alone, because the extension profiles (official Telegram's included) do not grant that key and asking for it breaks the extension's install and upload, while sender avatars work from the main app's entitlement. `tools/dev/tests/test_platform_hardening.py` pins this. (2) Apple Enhanced Security: `--//Telegram:enhancedSecurity` adds `hardened-process`, version `1`, `checked-allocations` and its `soft-mode` to the app, Notification Service and Share; `--//Telegram:enhancedSecurityRestrictions` adds `dyld-ro` and `platform-restrictions-string` 2 (no soft mode). Both default off in Bazel: the App IDs need the Enhanced Security capability in the developer portal first (App Store Connect's `capabilityType` list has no Enhanced Security value, so it cannot be enabled by API) and the profiles regenerated, otherwise signing fails. Pass them with `--bazelArguments`. `tg device` adds `--//Telegram:enhancedSecurity` when the development profiles of the app, NotificationService and Share grant `hardened-process`; `tg testflight` requires it (it stops before building if a profile lacks it) and `device_signing.py testflight` checks the exported App Store build and its distribution profiles before the upload (`TG_TF_ENHANCED_SECURITY=0` ships without; RH1). Raise the version string to `2` for guard objects after a clean soft-mode cycle. (3) `.bazelrc` compiles all C, C++ and Objective-C with `-ftrivial-auto-var-init=zero`, `_LIBCPP_HARDENING_MODE_FAST` and `-fstack-protector-strong`; libraries built by their own scripts keep their own flags. (4) Voice Calls privacy has "Show Calls in Phone Recents" (`VoiceCallSettings.showCallsInRecents`, default on, mirrored to `UserDefaults` by `CallKitPrivacy` so a cold-start VoIP push sees it): off sets `CXProviderConfiguration.includesCallsInRecents = false` and stops the Siri donations of calls (the app's outgoing one, and the Notification Service's ringing-call one via `IncomingCallCommunication.donatesCall`); that donation also waits for the same no-passcode check the message donations use.

**Running tests.** `Make.py test` runs Bazel test targets (same config + codesigning as `build`, forced `debug_sim_arm64`). It accepts `--target <label>` (added 2026-06-19; default `Tests/AllTests`) so a single `ios_unit_test` can run in isolation, e.g.:

```sh
source ~/.zshrc 2>/dev/null; python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
 test --configurationPath build-system/appstore-configuration.json \
 --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git \
 --gitCodesigningType development --gitCodesigningUseCurrent --target //submodules/TextFormat:TextFormatTests
```

The first app-side `ios_unit_test` is `//submodules/TextFormat:TextFormatTests` (the mention/date link codecs). An `ios_unit_test` here needs an `ios_test_runner` pinned to a real device/OS — the default runner picks an invalid device and the test process exits 15. Every runner takes `device_type = TEST_SIMULATOR_DEVICE, os_version = TEST_SIMULATOR_OS` from `//build-system/bazel-utils:test_simulator.bzl` (iPhone 17 / iOS 27.2, the only simulator runtime installed); update the pair there, not per BUILD file, after an Xcode update. **Run new targets via `--target`, not the default suite:** `Tests/AllTests` currently references a dangling `//submodules/TgVoipWebrtc:TgCallsTests`, so the default would fail to build until that suite is repaired.

Pure C++ units have host `cc_test`s that bypass Make.py entirely (macOS build, no codesigning):
`./build-input/bazel-9.3.1-darwin-arm64 test //submodules/TgVoipWebrtc:streaming_audio_renderer_test --test_output=all`
(likewise `:mtproto_ice_transport_test`). `//third-party/libprisma:SyntaxHighlighterTests` (added
2026-09-25) is the same kind of target outside tgcalls: it compiles only libprisma's pure-C++ core
(not `Syntaxer.mm`, which needs UIKit) plus header-only `boost_regex`, loads the real shipped
`grammars.dat` (passed via the target's `args = ["$(location libprisma/libprisma/grammars.dat)"]`), and pins the
**code-block highlighter recursion bound** — highlighting a `brightscript` block whose grammar has a
token cycle used to recurse `tokenize()`/`matchGrammar()` without limit and kill the process with a
stack overflow (a remote DoS: the block is highlighted on receipt). `SyntaxHighlighter::kMaxTokenizeDepth`
(now 32) caps it and degrades gracefully to plain text at the cap.
Since 2026-11-04 `third-party/libprisma` is the single copy both apps build (the Mac `CodeSyntax`
framework compiles these Sources and bundles this `grammars.dat`, no longer `submodules/libprisma`): it is
`desktop-app/libprisma` master 94640c6 (depth cap 32, a per-call regex-search budget of 64 searches per byte
plus 1024, thread-safe `const tokenize`, lazy pattern compile, 12 more languages than the old iOS copy) with
`TokenizeStats`/`TokenizeLimits` added so the host test can assert the bounds. Since the shared-libraries work it is the
klaipher/libprisma submodule (`third-party/libprisma/libprisma`, branch `nanogram`, also Android's source); refresh it there, not here. They follow a plain `CHECK_TRUE` + `main()` pattern, are listed
explicitly in `submodules/TgVoipWebrtc/BUILD` (group sources are not globbed), and must be added to the
`exclude:` list in `tgcalls/Package.swift` so SwiftPM does not compile their `main()`. The first run compiles
WebRTC for the host (~2.5 min); later runs take seconds. Note the binary is version-stamped and
arch-suffixed (`bazel-9.3.1-darwin-arm64` since 2026-09-14, was `bazel-8.4.2-darwin-arm64`), not the
bare `bazel-8.4.2` the tgcalls CLAUDE.md names; `versions.json` is the single pin.

`//submodules/MetalEngine:MetalPipelineCacheTests` (added 2026-10-01) is the first host `swift_test`, run
the same way (`… bazel-9.3.1-darwin-arm64 test //submodules/MetalEngine:MetalPipelineCacheTests`; one test
via `--test_filter=MetalPipelineCacheTests/<name>`, comma lists are not supported). It compiles only
`MetalPipelineCache.swift` + `MetalBinaryArchiveSerialization.swift` and runs on the Mac's GPU, because
the simulator has no binary archives (serializing fails an assertion there). It pins an **Apple bug**: a
`MTLBinaryArchive.serialize(to:)` whose final file move fails does not throw — Metal frees the error on
the compiler's reply thread and the caller crashes retaining it (device crash on iOS 26.3, reproduced on
macOS 27). `MetalBinaryArchiveSerialization` hooks that one `NSFileManager` call to keep the error alive;
the target sets `NSZombieEnabled` so a regression fails deterministically.

`//submodules/UrlWhitelist:UrlWhitelistTests` (added 2026-10-06) is a host `swift_test` like
`MTProtoRustEngineMappingTests`, run the same way. It pins `externalUrlWithLoginPart`, the check that
makes opening a link with a login part in front of its host ask first: in
`https://telegram.org∕test∕@evil.org` the `∕` (U+2215) is not a slash, so `telegram.org∕test∕` is a user
name and the link opens evil.org. The check runs in the external-URL opener (`openExternalUrlImpl`),
which every external link leaves through, including the openers that never ask about anything (admin
log, Instant View), and its parse is the opener's own (`canonicalExternalUrl`, now in `UrlWhitelist`).
The prompts in `openUserGeneratedUrl` and `TextLinkHandling` also flag such links. Every prompt, and
the title of every long-press link menu (`displayUrlRevealingLoginPart`; Copy still copies the link as
written), shows the address without the login part, and accepting a prompt records the address
(`noteLoginPartConfirmed`) so the opener does not ask a second time. The check stays out of `parseUrl`,
whose `concealed` flag also makes the shared-links list title a link with its whole address instead of
its host.
