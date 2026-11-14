# Export compliance (encryption)

Sources: Apple, "Complying with Encryption Export Regulations" https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations ;
App Store Connect help, export compliance https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance ;
US BIS EAR 740.17 (mass market) and 742.15.

## What the app uses

MTProto 2.0 (AES-256 in IGE mode, RSA, Diffie-Hellman, SHA-256/SHA-1), TLS and HTTPS through the system, SRTP/DTLS in calls (WebRTC), end-to-end secret chats, local database encryption (SQLCipher-style key), passcode hashing. All of it serves messaging between users and protecting the user's data; the app has no other cryptographic function (no VPN, no crypto API for third parties).

## What the official Telegram app does

`Telegram/BUILD` (Info.plist fragment, line ~1761), `Telegram/Telegram-iOS/Info.plist` and `InfoBazel.plist` set `ITSAppUsesNonExemptEncryption` to `false`. Nanogram inherits the same value.

## Info.plist

Current state: `<key>ITSAppUsesNonExemptEncryption</key><false/>` already present in the main app Info.plist fragment. No change needed, and nothing was applied. (Extensions do not need the key.) With the key set to false, App Store Connect does not ask the export question on each upload.

## Caution (owner decision)

Apple's exemption wording covers encryption that is standard (accepted by IEEE, IETF, ITU) or used only for authentication, digital signatures or the OS's own functions. MTProto is a proprietary protocol built from standard algorithms, so a strict reading puts it in "other encryption", which is still eligible for US License Exception ENC through mass-market self-classification (not a license). Telegram's own app answers "exempt"; the owner's instruction is the same. Recommended answers:

- If the App Store Connect questionnaire appears (key absent): "Does your app use encryption?" Yes. "Does it qualify for exemption (standard algorithms / mass market)?" Yes, exempt.
- Do not claim "no encryption".

## Annual self-classification report

Only if the app is treated as using non-standard cryptography under 740.17(b)(1): then a self-classification report to BIS and the ENC Unit is due each year by 1 February for the previous year's products (email to crypt-supp8@bis.doc.gov and enc@nsa.gov per 740.17(e)(3)). If the exemption answer stands, no report is filed. France and some other countries ask for a declaration only for non-exempt apps; with the exempt answer none is needed. This section is not legal advice: confirm with the owner's counsel once, since the owner also sells the Mac edition.
