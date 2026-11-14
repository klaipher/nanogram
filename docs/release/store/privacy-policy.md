# Nanogram Privacy Policy

Last updated: 2026-11-14

Nanogram is an unofficial client for the Telegram network. It is built on the open Telegram API. It is not made or endorsed by Telegram.

## Who handles your data

- Messages, media, contacts you upload, your phone number, your profile and everything you do in chats are sent to and stored by Telegram's servers. Telegram's own policy applies to that data: https://telegram.org/privacy
- Nanogram has no servers of its own for accounts, messages or files. The developer of Nanogram does not receive your messages, your phone number, your contacts or your files.
- Nanogram has no analytics, no advertising and no tracking SDKs. Nothing in the app is used to track you across other companies' apps or websites.

## What stays on your device

- Your local message database, caches, settings and passcode data. Crash and diagnostic logs are kept on the device.
- On-device voice transcription and on-device translation (optional, in Settings > Nanogram Features) use Apple's on-device speech and Translation frameworks. The audio or text you process this way is not sent to Telegram or to us for that purpose. If the on-device result is missing, the app may fall back to Telegram's server feature, which is then covered by Telegram's policy.

## Push notifications

To deliver notifications Nanogram registers a push token with Apple (APNs). The token is sent to Telegram, which sends the notification through Apple. A Firebase project is used only as a delivery channel for push verification messages; no Firebase analytics or other Firebase SDK runs in the iOS app.

## Diagnostics

Nanogram can create a diagnostic report (Settings, Send Report). The report is created only when you press the button. You choose where it goes (a chat, email or another app). It is not sent to the developer automatically.

## Permissions

Camera, microphone, photos, contacts, location, Face ID, speech recognition and notifications are asked for only when you use the matching feature. Contacts you choose to sync are uploaded to Telegram, not to us.

## Web content

Links can open in the in-app browser or in another browser you choose. Websites you visit see your usual browser data; Nanogram can remove common tracking parameters from links (option, on by default where noted in settings).

## Your choices and deletion

- You can delete your Telegram account inside the app: Settings > Privacy and Security > Delete My Account. This is handled by Telegram.
- You can delete local data by logging out or removing the app.
- Questions about data held by Telegram go to Telegram: https://telegram.org/privacy

## Children

Nanogram is rated for older users because chats can contain user-generated content. It is not directed at children.

## Contact

See the support page: https://klaipher.github.io/nanogram-releases/support/ or write to {{SUPPORT_EMAIL}}.

## Changes

Changes to this policy are posted on this page with a new date.

---
Notes for the owner (delete before publishing): Apple 5.1.1(i) requires a privacy policy link in App Store Connect and in the app (https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage). Claims verified in the code: no analytics SDK is linked (grep for Firebase, Crashlytics, Mixpanel, Amplitude, AppsFlyer, AppMetrica, Sentry in Telegram/, submodules/, third-party/ found no SDK; the `firebase*` names in `AppDelegate.swift` are the push-based verification secrets that Telegram's login flow uses, not the Firebase SDK); Send Report is user-initiated (`DebugReportSources.swift`); the only third-party app URL schemes queried are comgooglemaps, googlechrome and similar (Info.plist LSApplicationQueriesSchemes). Re-verify the "Firebase" sentence against the build you submit; if the build has no Firebase involvement, delete that sentence.
