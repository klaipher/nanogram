# Nanogram: App Store listing (en-US)

Sources: App Store Review Guidelines https://developer.apple.com/app-store/review/guidelines/ (2.3 accurate metadata, 4.1 copycats, 5.1.1 privacy policy);
Telegram API Terms https://core.telegram.org/api/terms (checked 2026-11-14); `NANOGRAM-CHANGES.md`, `CHANGELOG.md`.
Same text serves the iOS app and the Mac App Store edition unless noted.

## Telegram API terms that bind this listing (quoted)

- 2.1 "You must obtain your own api_id for your application." (Nanogram has its own.)
- 2.2 Users must know the app uses the Telegram API and is part of the Telegram ecosystem; this must be prominently disclosed in app store descriptions and in any in-app intro. The description below says so in its first paragraph.
- 2.3 "the title of your app must not include the word 'Telegram'" (exception only for "Unofficial Telegram"). The name is "Nanogram"; the word never appears in name, subtitle or keywords. It is used in the description only to state the API relation, which 2.2 requires.
- 2.4 "You must not use the official Telegram logo for your app." The icon is Nanogram's own.
- 1.3 / 1.4: all basic Telegram features must work and not be interfered with (no hidden actions on the user's behalf).

## Fields

| Field | Value | Limit |
|---|---|---|
| Name | Nanogram | 30 |
| Subtitle | Fast, private chat client | 30 (25 used) |
| Promotional text | A fast, battery-friendly chat app built on the open Telegram API. Voice transcription and translation can run on your device. Unofficial; not affiliated with Telegram. | 170 (167 used) |
| Primary category | Social Networking | |
| Secondary category | Productivity | |
| Support URL | https://klaipher.github.io/nanogram-releases/support/ | |
| Privacy policy URL | https://klaipher.github.io/nanogram-releases/privacy/ | |
| Marketing URL | https://klaipher.github.io/nanogram-releases/ | |
| Copyright | 2026 Nanogram | |
| Price | Free, no in-app purchases | |

## Keywords (<= 100 characters; 99 used)

```
messenger,chat,messages,voice,calls,secret chat,widgets,watch,translate,transcribe,groups,channels
```

No competitor or brand names (no "Telegram", "WhatsApp", "Signal"). Re-count with `printf %s '<line>' | wc -c` before pasting.

## Description (<= 4000)

```
Nanogram is an unofficial chat app for the open Telegram network. It uses the open Telegram API and builds on Telegram's open-source apps. It is not made, endorsed or sponsored by Telegram, and it is not the official Telegram app. You sign in with your existing Telegram account and talk with the same people, groups and channels as before.

Nanogram runs no message servers of its own: your messages travel between your device and Telegram's servers, and Nanogram adds no analytics, no advertising and no tracking.

FAST AND LIGHT
- Smoother scrolling, quicker chat opening and less battery use in the background
- Smaller storage use, with caches that clean up after themselves
- Calls with better audio, including optional noise suppression and a thermal limit for video when the phone gets hot

PRIVATE BY DESIGN
- Voice messages can be turned into text on your device, and messages can be translated on your device, so the content stays on the phone
- Remove tracking parts from links before you open or share them
- Confirm before opening Telegram links, passcode and Face ID lock, secret chats
- Diagnostics leave the phone only when you tap Send Report, and only to the chat or app you pick

NANOGRAM FEATURES
- Search operators for finding messages quickly
- Options for calls, links and on-device language tools in one place: Settings > Nanogram Features
- Rich text composer, InstantView pages and message widgets (can be switched off)

MADE FOR APPLE DEVICES
- Apple Watch app with chats, voice messages and an unread widget
- Home Screen and Lock Screen widgets, Live Activities, Siri and Shortcuts
- iPhone and iPad, including resizable windows and Split View on iPad

EVERYTHING YOU EXPECT
- Messages, groups, channels, bots, stickers, reactions, polls, folders
- Voice and video calls and group calls
- Files up to 2 GB, voice and video messages, photo and video editing
- Multiple accounts and secret chats with end-to-end encryption

Nanogram does not sell anything. Telegram Premium, Stars and gifts are bought through Telegram's own apps; this app does not offer those purchases. Content you already have keeps working.

Telegram is a trademark of its owner. Nanogram is an independent project that uses the Telegram API under the Telegram API Terms of Service.

Questions or problems: https://klaipher.github.io/nanogram-releases/support/
Privacy policy: https://klaipher.github.io/nanogram-releases/privacy/
```

Keep the opening paragraph (API terms 2.2).

Feature claims and where they are true: performance and cache work (NANOGRAM-CHANGES "Storage, media, performance"); on-device transcription/translation switches (Settings > Nanogram Features > ON-DEVICE, default off); Send Report; Apple Watch app and unread widget (CHANGELOG IOS-WATCH-WIDGET-1); calls switches. Drop any line the build does not ship (watch and widget lines if the submitted build lacks them; Mac edition: remove the Apple Watch and iPad lines).

## What's New (first release)

```
First App Store release of Nanogram, an unofficial client for the Telegram network.
```
