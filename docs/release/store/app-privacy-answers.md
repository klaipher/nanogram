# App Store Connect: App Privacy answers

Sources: https://developer.apple.com/app-store/app-privacy-details/ and guideline 5.1.1/5.1.2
(https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing). Reference: Telegram's own App Store label (Contact Info, Contacts,
User Content and Identifiers, "linked to you", no tracking; read it again at https://apps.apple.com/app/telegram-messenger/id686449807 under App Privacy before clicking).
Apple's rule: data counts as "collected" when it leaves the device to the developer or a partner. Nanogram's backend is Telegram's service,
which the app talks to on the user's behalf, so the data below is declared the same way Telegram declares it. Nanogram's developer runs no server and receives none of it.

Where: App Store Connect > the app > App Privacy > Get Started (or Edit) > Publish. The owner clicks all of it (the API has no endpoint for this).

## Step 1: "Do you or your third-party partners collect data from this app?"  Yes

## Step 2: data types to tick

| Category | Data type | Linked to user | Used for tracking | Purposes |
|---|---|---|---|---|
| Contact Info | Phone Number | Yes | No | App Functionality |
| Contacts | Contacts | Yes | No | App Functionality |
| User Content | Other User Content (messages, files, voice) | Yes | No | App Functionality |
| User Content | Photos or Videos | Yes | No | App Functionality |
| User Content | Audio Data | Yes | No | App Functionality |
| Identifiers | User ID | Yes | No | App Functionality |
| Location | Precise Location (only when the user sends a location) | Yes | No | App Functionality |

Owner choice: Telegram's label lists the first four groups only; Photos or Videos, Audio Data and Precise Location are the same content sent as messages and are covered by "Other User Content" in Telegram's label. Ticking them too is the stricter reading and cannot cause a mismatch finding; ticking only Telegram's set follows the official app. Recommendation: tick the full table above.

Not collected (answer "No" / leave unticked): Health and Fitness, Financial Info, Sensitive Info, Browsing History, Search History, Purchases, Diagnostics (Send Report is user-initiated and goes to a chat or app the user picks, not to the developer; no crash reporter is linked), Usage Data, Advertising Data, Device ID (no IDFA or IDFV is read for analytics), Coarse Location.

## Step 3: for every ticked type

- "Is this data linked to the user's identity?"  Yes
- "Do you or your partners use this data for tracking purposes?"  No
- Purpose: App Functionality only (not Analytics, not Advertising, not Personalization, not Product Personalization).

## Step 4: Tracking

"Used for tracking": none. Do not add NSUserTrackingUsageDescription; no ATT prompt exists.

## Result label

"Data Linked to You": Contact Info, Contacts, User Content, Identifiers, Location. "Data Used to Track You": none.

## Privacy choices URL (optional)

https://klaipher.github.io/nanogram-releases/privacy/

## Owner must click

1. All of Step 1-4 above, then Publish.
2. Privacy Policy URL field (App Information): https://klaipher.github.io/nanogram-releases/privacy/
3. Re-check the table if a build adds an analytics or crash SDK (it would change Diagnostics/Usage Data).
