# App Store Connect: App Privacy answers

Sources: https://developer.apple.com/app-store/app-privacy-details/ and guideline 5.1.1/5.1.2
(https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing). Reference: Telegram's own App Store label (Data Linked to You: Purchases, Financial Info, Location, Contact Info, Contacts, User Content, Identifiers; no tracking; read it again at https://apps.apple.com/app/telegram-messenger/id686449807 under App Privacy before clicking).
Apple's rule: data counts as "collected" when it leaves the device to the developer or a partner. Nanogram's backend is Telegram's service,
which the app talks to on the user's behalf, so the data below is declared the same way Telegram declares it. Nanogram's developer runs no server and receives none of it.

Where: App Store Connect > the app > App Privacy > Get Started (or Edit) > Publish. The owner clicks all of it (the API has no endpoint for this).

## Step 1: "Do you or your third-party partners collect data from this app?"  Yes

## Step 2: data types to tick

| Category | Data type | Linked to user | Used for tracking | Purposes |
|---|---|---|---|---|
| Contact Info | Phone Number | Yes | No | App Functionality |
| Contact Info | Name | Yes | No | App Functionality (sign-up name, shipping name) |
| Contact Info | Email Address | Yes | No | App Functionality (login and 2-step email, payment forms) |
| Contact Info | Physical Address | Yes | No | App Functionality (shipping info in bot payments) |
| Financial Info | Payment Info | Yes | No | App Functionality (bot payment forms for goods and services) |
| Purchases | Purchase History | Yes | No | App Functionality (bot payments and Stars spending still work) |
| Diagnostics | Performance Data | Yes | No | Analytics, App Functionality (connection and download statistics, network telemetry when the server enables it) |
| Diagnostics | Other Diagnostic Data | Yes | No | App Functionality (short error logs after a login reset) |
| Usage Data | Product Interaction | Yes | No | Analytics (some interface events, split-test events) |
| Contacts | Contacts | Yes | No | App Functionality |
| User Content | Other User Content (messages, files, voice) | Yes | No | App Functionality |
| User Content | Photos or Videos | Yes | No | App Functionality |
| User Content | Audio Data | Yes | No | App Functionality |
| Identifiers | User ID | Yes | No | App Functionality |
| Location | Precise Location (only when the user sends a location) | Yes | No | App Functionality |

Owner choice: Photos or Videos, Audio Data and Precise Location are the same content sent as messages and are covered by "Other User Content" in Telegram's label. Ticking them too is the stricter reading and cannot cause a mismatch finding. The Contact Info, Financial Info, Purchases, Diagnostics and Usage Data rows are in the table because the app sends that data to Telegram: payment forms (`payments.validateRequestedInfo`, `payments.sendPaymentForm`) and the automatic app events the iOS client sends through `help.saveAppLog` (short logs, UI events, download statistics, split-test events, network telemetry when the server enables it). Per the owner rule on upstream data behaviour, these flows are disclosed, not removed. Recommendation: tick the full table above.

Not collected (answer "No" / leave unticked): Health and Fitness, Sensitive Info, Browsing History, Search History, Advertising Data, no crash reporter SDK is linked (Send Report is user-initiated and goes to a chat or app the user picks, not to the developer), Device ID (no IDFA or IDFV is read for analytics), Coarse Location.

## Step 3: for every ticked type

- "Is this data linked to the user's identity?"  Yes
- "Do you or your partners use this data for tracking purposes?"  No
- Purpose: App Functionality for every type; add Analytics for Performance Data and Product Interaction. Never Advertising, Personalization or Product Personalization.

## Step 4: Tracking

"Used for tracking": none. Do not add NSUserTrackingUsageDescription; no ATT prompt exists.

## Result label

"Data Linked to You": Purchases, Financial Info, Location, Contact Info, Contacts, User Content, Identifiers, Diagnostics, Usage Data. "Data Used to Track You": none.

## Privacy choices URL (optional)

https://klaipher.github.io/nanogram-releases/privacy/

## Owner must click

1. All of Step 1-4 above, then Publish.
2. Privacy Policy URL field (App Information): https://klaipher.github.io/nanogram-releases/privacy/
3. Re-check the table if a build adds an analytics or crash SDK of its own (Diagnostics and Usage Data are already declared for Telegram's own events).
