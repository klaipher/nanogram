# App Review notes (full App Store submission)

Sources: Review Guidelines https://developer.apple.com/app-store/review/guidelines/ , especially 1.2 (user-generated content), 3.1.1 (in-app purchase), 4.2 (minimum functionality),
5.1.1(v) (account deletion), 2.1 (demo account). Telegram API Terms https://core.telegram.org/api/terms .
Paste into App Store Connect > App Review Information > Notes; the demo account goes into the sign-in fields.

```
Nanogram (org.klaipher.Nanogram) is an unofficial client for the Telegram messaging network. It uses the open Telegram API with our own api_id, as the Telegram API Terms require (section 2.1), and it states this in the description (section 2.2). The name and icon are our own and do not use Telegram's name or logo (2.3, 2.4). A Mac App Store edition of the same app is submitted separately.

LOGIN
Sign-in needs a phone number and a one-time code that Telegram sends to the user. Demo account: phone {{DEMO_PHONE}}. {{DEMO_CODE_INSTRUCTIONS}}
If the code does not arrive, the Telegram servers may be rate limiting; please wait a few minutes and request it again, or contact {{SUPPORT_EMAIL}}.

PURCHASES (3.1.1)
Telegram sells Premium, Stars and gifts through Telegram's own App Store products. This app has no in-app purchases and does not link to or offer any other payment method for digital goods: those purchase screens are removed or disabled in this build. Stars and gifts the user already owns can still be viewed and used. There are no subscriptions.

USER-GENERATED CONTENT (1.2)
Chats are private between users; public groups and channels exist. Controls: Report on any message, chat, channel, user and bot (long press or profile menu); Block user (profile menu); delete own messages; mute or leave groups; Telegram's moderators act on reports and ban abusive accounts server-side. Contact for abuse: {{SUPPORT_EMAIL}}. The age rating is 18+ because of user content and unrestricted web access.

ACCOUNT DELETION (5.1.1(v))
In the app: Settings > Privacy and Security > Delete My Account (self-destruct period or immediate deletion through Telegram's flow).

PRIVACY
No analytics, advertising or tracking SDKs. Messages go to Telegram's servers. Push tokens go to Telegram (APNs). Diagnostics are sent only when the user presses Send Report. Voice transcription and translation can run on the device. Privacy policy: https://klaipher.github.io/nanogram-releases/privacy/

PERMISSIONS
Camera, microphone, photos, contacts, location, Face ID, speech recognition and notifications are requested when the user uses the matching feature. Live Location uses background location only while the user shares it.

OTHER
Calls use CallKit and VoIP-style push through the normal notification path. Encryption: standard and proprietary-protocol messaging encryption, exempt (ITSAppUsesNonExemptEncryption=false).
```
