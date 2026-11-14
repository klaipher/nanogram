# TestFlight external testing

Sources: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information ; Review Guidelines 2.1 (demo account) https://developer.apple.com/app-store/review/guidelines/#performance .
API: `betaAppLocalizations` (description, feedbackEmail, marketingUrl, privacyPolicyUrl, tvOsPrivacyPolicy), `betaAppReviewDetails` (contactFirstName, contactLastName, contactPhone, contactEmail, demoAccountName, demoAccountPassword, demoAccountRequired, notes), `betaBuildLocalizations.whatsNew`.

## Beta app description

```
Nanogram is an unofficial client for the Telegram network, built on the open Telegram API. It is not made or endorsed by Telegram. Test messaging, calls, voice transcription and translation on device, widgets and the Apple Watch app. Please report problems with Settings > Send Report.
```

## Feedback email

{{SUPPORT_EMAIL}}

## URLs

Marketing https://klaipher.github.io/nanogram-releases/ ; Privacy https://klaipher.github.io/nanogram-releases/privacy/

## Default What to Test (per build: replace with the changelog written for that upload)

```
Sign in with your Telegram account, send and receive messages, make a call, and try the on-device options in Settings > Nanogram Features. If something is wrong, use Settings > Send Report.
```

## Beta review notes (betaAppReviewDetails.notes)

```
Nanogram is an unofficial Telegram client using our own Telegram api_id, under the Telegram API Terms. Sign in needs a phone number and a login code sent by Telegram. Use the demo account below. Telegram Premium, Stars and gift purchases are not offered in this app. No account needs to be created. Account deletion: Settings > Privacy and Security > Delete My Account. Report and block exist in every chat and profile menu.
```

## Demo account (owner provides)

- demoAccountRequired: true
- Phone: {{DEMO_PHONE}}
- Login code: {{DEMO_CODE_INSTRUCTIONS}}
  (A Telegram account receives its code in another Telegram session, so reviewers cannot read it. Use a Telegram test number or leave a signed-in second device online, and write exactly where the code appears and how long the account stays available. If two-step verification is on, put the password here too.)
- Contact: first name, last name, phone, email of the owner (betaAppReviewDetails contact fields).
