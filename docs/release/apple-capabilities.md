# Nanogram: Apple capabilities checklist

App: **org.klaipher.Nanogram** · Team **YGTMYL879P** · App Store Connect Apple ID **6829268176** · distributed through TestFlight, not on the App Store yet.
Targets that ship in the app (`Telegram/BUILD`): main app, `.Share`, `.NotificationContent`, `.NotificationService`, `.SiriIntents`, `.Widget`, `.BroadcastUpload` (plus `.watchkitapp` when the watch app is embedded).
Checked 2026-11-02 against official Telegram's entitlements in `Telegram/BUILD` (lines ~462–614; the `TelegramEntitlements` list is at line 599). Only the main app has an `entitlements =` file (`Telegram/BUILD:1968`); every extension except `.Share` (`:1166`) has none, so rules_apple signs it with the entitlements in that extension's provisioning profile.

**Portal path used below.** "Portal > Nanogram" means: developer.apple.com > Account > **Certificates, Identifiers & Profiles** > **Identifiers** > `org.klaipher.Nanogram` > **Capabilities** tab (Apple's steps word it as "click **Edit**") > tick the box > **Save** > **Confirm** if a warning dialog appears.
Apple's steps: https://developer.apple.com/help/account/identifiers/enable-app-capabilities

**Every time you change a capability, the old provisioning profiles stop working.** Apple: "Provisioning profiles that contain a modified App ID become invalid. You'll need to regenerate the provisioning profiles that use that App ID." (same link). After any change, regenerate the App Store / ad hoc profiles and put them in your signing profiles folder before you run `tg testflight` or `tg device`.

## Summary

| # | Item | Status | Action | Where |
|---|------|--------|--------|-------|
| 1 | Communication Notifications | ✅ Done | Nothing | Portal > Nanogram > Communication Notifications |
| 2 | Notification filtering | ⏳ Waiting on Apple | Wait; then 2 repo changes + profiles | Request form: developer.apple.com/contact/request/notification-service |
| 3 | Siri | ❌ Off | **Do now** (5 min) | Portal > Nanogram > **Siri** + `enable_siri: true` |
| 4 | CarPlay (Communication) | ❌ Off | Later (after Siri) | developer.apple.com/contact/carplay/ (redirects to /contact/request/carplay/) |
| 5 | iCloud | ❌ Off | Skip for now | Portal > Nanogram > **iCloud** + container |
| 6 | Unrestricted VoIP pushes | ❌ Off | Skip | No form exists |
| 7 | Associated domains (t.me links) | ❌ Off | Impossible | Controlled by Telegram's t.me server |
| 8 | Apple Pay merchant IDs | ❌ Off | Impossible | Belong to Telegram's team |
| 9 | Sign in with Apple | ❌ Off | Skip | Portal > Nanogram > Sign in with Apple |
| 10 | Background GPU Access | ❌ Off | Skip | Xcode/portal capability "Background GPU Access" |
| C1 | `appstore_id` | 686449807 (Telegram's) | Change at App Store release | `~/.config/telegram-ios/device-configuration.json` |
| C2 | `is_appstore_build` | false | Set true for a public build | same file |

## Already done

- **#1 Communication Notifications**, done 2026-11-02. The portal capability is ticked, and `Telegram/BUILD` grants `com.apple.developer.usernotifications.communication` to `org.klaipher.Nanogram` (`communication_notifications_bundle_ids`, line 576).

## Waiting on Apple

- **#2 Notification filtering.** Request sent through the form; approval is pending.
- (Optional, later) **#4 CarPlay messaging**, once you request it.

---

## Details

### 1. Communication Notifications (`com.apple.developer.usernotifications.communication`) ✅
- **Gives the user:** notifications that show the sender's avatar, like iMessage does (the NotificationService extension's `INSendMessageIntent` only works with this entitlement).
- **Status:** done. **Type:** self-service. Apple lists it as a standard iOS capability: https://developer.apple.com/help/account/reference/supported-capabilities-ios
- **Where:** Portal > Nanogram > **Communication Notifications**.
- **Note:** the App Store Connect API **cannot** set it, because its `CapabilityType` list has no communication-notifications value (https://developer.apple.com/documentation/appstoreconnectapi/capabilitytype). It has to be done in the portal, and that is how it was done. The API **can** set `SIRIKIT`, `ICLOUD` and `APPLE_ID_AUTH` (same page).
- **Verify:** `codesign -d --entitlements :- Payload/Telegram.app` on the exported IPA shows the key.

### 2. Notification filtering (`com.apple.developer.usernotifications.filtering`) ⏳
- **Gives the user:** the notification extension can silently drop a push, so you don't get "You have a new message" banners for muted or deleted chats and duplicate or empty messages are hidden. Apple: "allows a notification service extension to receive remote notifications without displaying the notification to the user" (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering).
- **Status:** requested, pending. **Type:** needs Apple's approval.
- **Where:** https://developer.apple.com/contact/request/notification-service (Apple's link title: "Request Notification Service Entitlement"; linked from the entitlement page above; needs sign-in, so the form's fields are (unverified)). Use Apple ID 6829268176. If the app isn't on the store yet, Apple DTS says to leave out the App Store URL or use a placeholder (https://developer.apple.com/forums/thread/649172).
  You can check progress at Portal > Identifiers > `org.klaipher.Nanogram` > **Capability Requests** tab > **Status** (https://developer.apple.com/help/account/capabilities/capability-requests).
- **After approval:**
  1. Portal: on the **Capabilities** tab, enable the newly granted capability for `org.klaipher.Nanogram` **and** `org.klaipher.Nanogram.NotificationService`. Apple says approved managed capabilities show up in that list (capability-requests link above). Then regenerate both profiles.
  2. `Telegram/BUILD` lines 579–583 (the condition is on line 583): change `notification_filtering_fragment = ... if telegram_bundle_id == "ph.telegra.Telegraph"` so it also matches `org.klaipher.Nanogram`. This only affects the main app's entitlements, as it does for official Telegram; do it only after the main-app profile has the capability, or signing fails.
  3. The extension's entitlements come from `Telegram/BUILD` (`NotificationServiceEntitlements`, built by `extension_entitlements` in `Telegram/entitlements.bzl` since 2026-11-04), not from its profile: it gets `notification_filtering_fragment` as soon as step 2 adds the bundle to `notification_filtering_enabled`. The regenerated `NotificationService.mobileprovision` from step 1 must carry the key too, or the signed extension will not install or upload.
  4. `Telegram/NotificationService/Sources/ServicePushPresentation.swift:17`: make `appCanFilterNotifications(baseAppBundleId:)` return true for `org.klaipher.Nanogram`, and flip the `XCTAssertFalse` in `Telegram/NotificationService/Tests/ServicePushPresentationTests.swift:16`.
- **Verify:** `codesign -d --entitlements :- Payload/Telegram.app/PlugIns/NotificationService*.appex` shows the key. Apple also says the push must have `apns-push-type: alert` for the extension to be able to hide it; that header is set by Telegram's servers (unverified). `security cms -D -i <profile>.mobileprovision` shows it in the profile (Apple's verification method: https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities). On a device, a push for a muted chat should produce no banner.
- **Recommendation:** worth having. Wait for Apple, then do the changes above.

### 3. Siri (`com.apple.developer.siri`) — do now
- **Gives the user:** "Hey Siri, send a message to Anna on Nanogram", Siri reading messages aloud, and Siri contact suggestions. It is also **required before CarPlay** (#4).
- **Status:** off (`enable_siri: false`). **Type:** self-service. "Siri" is listed as a standard iOS capability (https://developer.apple.com/help/account/reference/supported-capabilities-ios). Apple: "The App Store requires the presence of this entitlement for iOS or watchOS apps containing Intents app extensions that handle any Siri requests other than shortcut requests" (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.siri). Nanogram already ships the `.SiriIntents` extension.
- **Where:** Portal > Nanogram > **Siri**. Or use the App Store Connect API: `POST /v1/bundleIdCapabilities` with `capabilityType: SIRIKIT` (https://developer.apple.com/documentation/appstoreconnectapi/post-v1-bundleidcapabilities).
- **Then:** in `~/.config/telegram-ios/device-configuration.json`, set `"enable_siri": true`. This turns on `siri_fragment` in `Telegram/BUILD` (line 547) and also compiles `APP_CONFIG_IS_SIRI_ENABLED=true` (`submodules/BuildConfig/BUILD:33`). Use a JSON boolean `true`, not the string `"true"`. Regenerate the main-app profile. `NSSiriUsageDescription` is already in the Info.plist (`Telegram/BUILD` ~line 1832).
- **Verify:** the IPA entitlements show `com.apple.developer.siri`. `GET /v1/bundleIds/{id}/bundleIdCapabilities` lists `SIRIKIT` (https://developer.apple.com/documentation/appstoreconnectapi/get-v1-bundleids-_id_-bundleidcapabilities). On the iPhone, the app's Settings page shows a Siri section (exact menu names vary by iOS version; unverified).
- **Recommendation:** **do now.** It's cheap, the extension already exists, and CarPlay depends on it.

### 4. CarPlay (`com.apple.developer.carplay-messaging` in official Telegram; `com.apple.developer.carplay-communication` is the current key) — later
- **Gives the user:** Nanogram messages read aloud and replied to by voice in the car (CarPlay).
- **Status:** off. **Type:** needs Apple's approval. Apple: "you must request the appropriate entitlement for your app's category at https://developer.apple.com/contact/carplay … Apple reviews each application using predefined criteria" (https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements). Apple also says "Messaging and VoIP apps that support SiriKit intents can be updated to appear in CarPlay" (https://developer.apple.com/carplay/).
- **Where:** https://developer.apple.com/contact/carplay/ (on https://developer.apple.com/carplay/ it's the "Request CarPlay app entitlement" link; it redirects to https://developer.apple.com/contact/request/carplay/ and needs sign-in). Pick the **Communication** category: Apple's entitlement table (requesting-carplay-entitlements link above) lists `com.apple.developer.carplay-communication` for "Communication" and has no separate Messaging category. `carplay-messaging`, which official Telegram uses, is the pre-iOS 14 key (https://developer.apple.com/documentation/carplay/supporting-previous-versions-of-ios). The form's exact category names are (unverified).
- **Then (after approval):** Portal > Nanogram > enable the CarPlay capability that appears there. Apple's CarPlay page calls the tab **Additional Capabilities**, and the capability-requests help page calls it **Capabilities**. In `Telegram/BUILD` lines 510–514, `carplay_fragment` currently applies only to `official_bundle_ids`; add `org.klaipher.Nanogram`, and make the key match what Apple granted (`carplay-communication` vs `carplay-messaging`). Regenerate the profile. Siri (#3) must already be on.
- **Verify:** the IPA entitlements show the granted CarPlay key. In Simulator choose I/O > External Displays > CarPlay (Apple's steps); where Nanogram shows up there is (unverified).
- **Recommendation:** **later**, after Siri is on. Approval times, and whether a live App Store page helps the request, are (unverified).

### 5. iCloud (CloudKit + iCloud Documents + key-value storage) — skip for now
- **Gives the user:** lets the app keep its own data in the user's iCloud. Low value for Nanogram, because picking files from iCloud Drive through the Files picker works without it.
- **Status:** off (`enable_icloud: false`). **Type:** self-service ("iCloud: CloudKit", "iCloud: iCloud documents" and "iCloud: iCloud key-value storage" are all standard capabilities: https://developer.apple.com/help/account/reference/supported-capabilities-ios).
- **Where:** Portal > Nanogram > **iCloud** > **Edit**, then assign or create the container `iCloud.org.klaipher.Nanogram`. Apple's steps are under "Enable iCloud" at https://developer.apple.com/help/account/identifiers/enable-app-capabilities (Edit > select the containers > Continue; if none exist, "Create iCloud Container"). The App Store Connect API value is `ICLOUD`, but the container is easiest to assign in the portal.
- **Then:** set `"enable_icloud": true` in the config. `Telegram/BUILD` (`icloud_fragment`, lines 516–534) then emits CloudKit + CloudDocuments, container `iCloud.{bundle}`, key-value store `{team}.{bundle}`, and an environment based on the APS environment. The container name must match exactly. Regenerate the profile.
- **Verify:** the IPA entitlements show `com.apple.developer.icloud-services` and `icloud-container-identifiers = iCloud.org.klaipher.Nanogram`.
- **Recommendation:** **skip** unless a feature actually needs it.

### 6. Unrestricted VoIP pushes (`com.apple.developer.pushkit.unrestricted-voip`) — skip
- **Gives the user:** lets the app wake through a VoIP push without showing a CallKit call (official Telegram has it).
- **Status:** off. **Type:** Apple only grants it in rare cases. **No request form.** An Apple DTS engineer wrote: "There isn't any submission point for this entitlement … it's really only granted if there simply isn't ANY other way for the app to function" (https://developer.apple.com/forums/thread/663956).
- **Repo:** `Telegram/BUILD` line 508 gives it only to `official_bundle_ids`. Leave it that way.
- **Recommendation:** **skip.** Normal push notifications plus the NotificationService extension already cover messaging.

### 7. Associated domains: `applinks:t.me`, `telegram.me` — impossible
- **Gives the user:** tapping a t.me link would open Nanogram directly.
- **Why impossible:** iOS only honours the link if the domain's `https://t.me/.well-known/apple-app-site-association` lists your app ID. Fetched 2026-11-02, its `applinks` section lists only `X834Q8SBVP.org.telegram.TelegramEnterprise`, `C67CF9S4VU.ph.telegra.Telegraph` and `X834Q8SBVP.org.telegram.Telegram-iOS`. Telegram controls that file.
- **Repo:** `associated_domains_fragment` (line 536) is correctly limited to official IDs. Leave it.
- **Recommendation:** **impossible.** t.me links open in Safari, which can hand off to Nanogram through the `tg://` URL scheme.

### 8. Apple Pay merchant IDs (Telegram's payment providers) — impossible
- **Gives the user:** Apple Pay in bot payments.
- **Why impossible:** Apple's steps assign merchant IDs by picking them from your account's Merchant ID table, or "Create Merchant ID" if there are none ("Enable Apple Pay" at https://developer.apple.com/help/account/identifiers/enable-app-capabilities). There is no way to add another team's merchant ID. The `merchant.*.telegramios` IDs belong to Telegram's team and its payment providers.
- **Repo:** `apple_pay_merchants` (line 493) is already empty for non-`ph.telegra.Telegraph` builds.
- **Recommendation:** **impossible.** Card payments through the provider's web form still work.

### 9. Sign in with Apple (`com.apple.developer.applesignin`) — skip
- **Gives the user:** Apple-ID login. Telegram logs in by phone number, so it isn't used.
- **Type:** self-service (Portal > Nanogram > **Sign in with Apple**; App Store Connect API value `APPLE_ID_AUTH`: https://developer.apple.com/documentation/appstoreconnectapi/capabilitytype). App Review Guideline 4.8 applies only to apps that use a third-party or social login service (Facebook, Google, etc.), and even then it asks for an equivalent privacy-preserving login option rather than naming Sign in with Apple (https://developer.apple.com/app-store/review/guidelines/#login-services). Phone-number login is not third-party login.
- **Repo:** `signin_fragment` (lines 585–591) is limited to `store_bundle_ids`. Leave it.
- **Recommendation:** **skip.**

### 10. Background GPU Access (`com.apple.developer.background-tasks.continued-processing.gpu`, iOS 26) — skip
- **Gives the user:** long GPU jobs, such as video export, can keep running after the app goes to the background.
- **Status:** off. **Type:** appears to be self-service. Apple: "add this entitlement to your app by adding the Background GPU Access capability to your target in Xcode" (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.gpu). Apple DTS: "No 'extra' approval or configuration is needed … it's currently only supported on iPad's with an M3 or better (and not supported on any iPhone)" (https://developer.apple.com/forums/thread/801229). It is **not** in Apple's list of standard iOS portal capabilities (https://developer.apple.com/help/account/reference/supported-capabilities-ios), so first check whether Portal > Nanogram shows a **Background GPU Access** checkbox. If it doesn't, add it once through Xcode's Signing & Capabilities for this App ID (whether that route works for this manually-signed App ID is unverified).
- **Then:** `Telegram/BUILD` lines 593–597: extend `background_gpu_fragment` to `org.klaipher.Nanogram`, then regenerate the profile.
- **Recommendation:** **skip.** It does nothing on any iPhone today. It would only help on M3+ iPads, where Nanogram's `BGContinuedProcessingTask` use (`submodules/TelegramUI/Sources/SharedWakeupManager.swift`) could get GPU time.

### Config items (`~/.config/telegram-ios/device-configuration.json`)
- **C1 `appstore_id`:** currently `686449807`, which is **official Telegram's** App Store ID. It is compiled in as `APP_CONFIG_APPSTORE_ID` (`submodules/BuildConfig/BUILD:30`), so in-app App Store links point to Telegram. Change it to **`6829268176`** once Nanogram's App Store page is live. **Later.**
- **C2 `is_appstore_build`:** currently `false`, compiled in as `APP_CONFIG_IS_APPSTORE_BUILD` (`submodules/BuildConfig/BUILD:29`). Set it to `true` only for the public App Store release build. **Later.**

## Verifying everything at once
1. **Exported IPA:** `unzip -q Nanogram.ipa -d x && codesign -d --entitlements :- x/Payload/Telegram.app`, then repeat for each `x/Payload/Telegram.app/PlugIns/*.appex`.
2. **Provisioning profile:** `security cms -D -i <profile>.mobileprovision`, then look at the `Entitlements` dict (https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities).
3. **App ID via API:** `GET /v1/bundleIds/{id}/bundleIdCapabilities` (https://developer.apple.com/documentation/appstoreconnectapi/get-v1-bundleids-_id_-bundleidcapabilities). Communication Notifications won't appear there because the API has no type for it, so check it in the portal instead.
