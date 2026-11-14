# Watch widget: what is automated and what to check (IOS-WATCH-WIDGET-1)

The widget extension (`WatchWidgetExtension`, `org.klaipher.Nanogram.watchkitapp.widget`) is part of the default watch
build and ships inside the watch app of the normal iOS build. `widgetSnapshot` and `backgroundRefresh` default to on.

## What the widget shows

Accessory circular, rectangular, inline and corner families (complications and Smart Stack). Total unread in unmuted
chats and the top two chats with unread messages. Chat names are hidden when the system redacts private content (locked
watch). Never message text. Smart Stack relevance rises with the unread count (`TimelineEntryRelevance`; the watchOS 26
`RelevanceConfiguration` API can replace it later).

## Already done (App Store Connect API)

- App ID `org.klaipher.Nanogram.watchkitapp.widget` exists.
- The App Groups capability is on for `org.klaipher.Nanogram.watchkitapp` and the widget App ID.

## Run before the build (once, and again when a profile expires)

`python3 tools/dev/device_signing.py profiles` with an iPhone connected. Xcode registers the App Group
`group.org.klaipher.Nanogram.watch` from the entitlements of the generated `WatchApp` and `WatchWidget` targets, assigns
it to both App IDs and creates their profiles in `~/.config/telegram-ios/codesigning/profiles`. `tools/dev/tg device
--watch` and `tools/dev/tg testflight --notes <file>` (it always embeds the watch app) pick `WatchApp.mobileprovision` and `WatchWidget.mobileprovision` up by themselves
and stop with this command in the message when only one exists. With neither, the watch app and the widget are signed
ad hoc with the group (good for a TestFlight export, not installable on a device).

## Checks on a watch (needs a device; nothing here was run)

1. Install the TestFlight build (a device build installs on a watch only if its UDID is registered on the team and in the regenerated profiles; `profiles` registers just the connected iPhone), open Nanogram on the watch once and sign in; wait for the chat list.
2. Add the Nanogram complication to a watch face (circular, rectangular, inline or corner) and to the Smart Stack.
   Expect the unread total; with the watch locked and private content hidden, expect no chat names.
3. Receive a message in a chat with the watch app closed. Expect the widget to update within the background refresh
   interval (about 30 minutes, within the system budget), or at once after opening the app.
4. If the widget stays empty: the app logs "widget snapshot enabled but the App Group is missing from the entitlements"
   when the group did not reach the app's signature (check the profile with `security cms -D -i`).
5. Turn either flag off without a rebuild: launch argument `-nanogram.watch.widgetSnapshot NO` or
   `-nanogram.watch.backgroundRefresh NO`.

## Xcode device runs

`cd Telegram/WatchApp && xcodegen generate --spec project-widget.yml` writes `tgwatch-widget.xcodeproj` (not committed)
with automatic signing for the app and the widget (team YGTMYL879P). Not needed for the iOS build.

## Not covered

Remote (Tart / darwin-containers) builds do not forward the widget profile flag; they resolve `WatchWidget.mobileprovision`
from the codesigning material and stop with the fix when it is missing.
