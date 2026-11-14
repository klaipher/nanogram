# Watch widget: owner steps (IOS-WATCH-WIDGET-1)

The widget extension code is in this directory and in `../Shared/`. It is **not** in the default build or in the IPA:
`project.yml` and the committed `tgwatch.xcodeproj` have no widget target. The extension needs things only the account
owner can create, so it stays out until they exist. Switch: generate `project-widget.yml` instead of `project.yml`.

## What the widget shows

Accessory circular, rectangular, inline and corner families (complications and Smart Stack). Total unread in unmuted
chats and the top two chats with unread messages. Chat names are hidden when the system redacts private content (locked
watch). Never message text. Smart Stack relevance rises with the unread count (`TimelineEntryRelevance`; the watchOS 26
`RelevanceConfiguration` API can replace it later).

## Steps, in order

1. Developer portal, Identifiers: register the explicit App ID `org.klaipher.Nanogram.watchkitapp.widget`.
2. Developer portal, Identifiers: register the App Group `group.org.klaipher.Nanogram.watch`; enable the App Groups
   capability on `org.klaipher.Nanogram.watchkitapp` (the watch app) and on the new widget App ID, and tick the group.
3. Profiles: regenerate the watch app's profile (it now has the group) and create one for the widget App ID. Nothing about
   these is readable by the agents; use the existing signing flow (`tools/dev/device_signing.py`) for the new App ID.
4. Device test with Xcode: `cd Telegram/WatchApp && xcodegen generate --spec project-widget.yml`, open
   `tgwatch-widget.xcodeproj`, run the `tgwatch Watch App` scheme on the watch (automatic signing, team YGTMYL879P), turn
   the flag on: launch argument `-nanogram.watch.widgetSnapshot YES` in the scheme. Add the widget to a watch face.
5. Bazel embed build (not done): `Telegram/prebuilt_watchos.bzl` signs one `.app`; embedding a second `.appex` needs the
   widget built and signed there with its own profile and entitlements (the group), and the app's own entitlements need
   the same group (the rule passes `entitlements = None` today). Do this after step 4 works.
6. Turn on `widgetSnapshot` for real builds by shipping its default as on (`WatchFeature.defaultValue`) once step 5 works.
   Optionally also `backgroundRefresh` so the summary stays fresh while the app is closed (no portal step needed for that).

## What happens without these steps

`widgetSnapshot` is off by default. With it on but no App Group entitlement, the app logs
"widget snapshot enabled but the App Group is missing from the entitlements" and writes nothing.
