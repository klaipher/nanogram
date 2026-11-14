# Mercurygram bug fixes and optimizations: iOS mirror (2026-11-14)

The full table is in the Android repo (docs/nanogram/mercurygram-port.md). This is the iOS view: every bug-fix,
security-fix and performance item of the analysis (`forks/research/mercurygram-analysis.md`, the diff:android and
diff:desktop lists, the evaluation and the Opus review), checked against Telegram-iOS code. Mercurygram Android is
GPL-2.0, mdesktop is GPLv3-or-later; nothing was copied, the one change below is written from the behaviour.

Statuses: ported, already had, not applicable, declined, open (checked, needs a device or a test pair).

| # | Item (Mercurygram commit) | Status on iOS | Reason / where |
| --- | --- | --- | --- |
| 1 | Push latch, one per push, bounded await (28fda5a3c) | not applicable | Android FCM code. iOS gets APNs through the system. |
| 2 | Push watchdog, keep-alive service, boot receivers | not applicable | Android services. |
| 3 | Crash pack of ten upstream crashes (1c9dcb6fd) incl. folder_id -1 badge wipe | not applicable | Java guards in Android classes; iOS has no counterpart code. Folder badges are computed from Postbox summaries, no array indexed by folder id. |
| 4 | Large-account slowdowns (b1274170f): admin-list re-fire (COMMUNITY_FILTER_INVALID), stale-history wedge, phantom dialogs | not applicable | The error string and request loop do not exist in iOS TelegramCore (grep). Chat list is a Postbox view, no manual rebuild. |
| 5 | Full dialog rebuild and folder badge recount on every deleted message | not applicable | Postbox updates unread counts incrementally per operation; nothing recounts all dialogs per delete. Not profiled. |
| 6 | TTL delete loops spawned in hundreds, readDiscussion only for unread topics | not applicable | Android scheduling code. |
| 7 | Memory leaks (ChatAvatarContainer, Bulletin, adapters ...) | not applicable | Android observer leaks. |
| 8 | Media I/O (793d5745a): "rws" to "rw", decode threads, stripped-thumb cache, bitmap cache | not applicable | Android FileLoadOperation and caches. iOS uses MediaBox. |
| 9 | Google DoH removed from proxy-hostname resolution | already had | `MTDNS resolveHostnameUniversal` is a native lookup only. Only the backup-config fetch still uses dns.google (kept, as on Android per owner decision). |
| 10 | Proxy hostname resolved natively, IPv6 results, all IPs tried | already had | `MTTcpConnection` resolves the proxy host with `MTDNS` (getaddrinfo, any family). |
| 11 | Notification sound reset to Default by opening its Sound screen (231015942) | already had | `notificationSoundSelectionController` starts from the stored sound and only reports a change when the user picks one. |
| 12 | Android 16 heads-up lists every unread chat (ede78cac5) | not applicable | Android notification groups. |
| 13 | Notification permission prompt on every launch (fd3d55126) | not applicable | The iOS system shows the prompt once; the app does not re-ask. |
| 14 | Live location "until stopped" treated as expired, int overflow (a2d04746f) | already had, hardened | Every expiry check short-circuits on `liveLocationIndefinitePeriod` before adding. One unguarded sum, extending a live location (`RequestEditMessage`), could trap on overflow for an indefinite one; it now stays indefinite (ported as hardening). |
| 15 | Theme colours lost with R8 (84e783f3b) | not applicable | R8 renaming. |
| 16 | Secret-chat delete-for-everyone (01230d2c1): send flush-history before discardEncryption | ported (shared core, iOS and Mac) | `RemovePeerChat.swift`: clear-history service message queued before the terminate operation, the chat turns terminated only after discardEncryption (`requestTerminateSecretChat`); `SecretChatTerminationPlanTests`. Needs a secret-chat test pair. |
| 17 | TL legacy readParams (layer81 draft, layer48 botInfo) | not applicable | iOS TelegramApi is generated, no legacy subclasses (analysis correction C1). |
| 18 | Livestream null audio decoder context crash (tgcalls) | already had | tgcalls fork 4f251c4 "Guard the audio decoder context in livestream decode". |
| 19 | Dice sticker cache restamping, PermissionRequest from services, RuntimeClassNameTypeAdapterFactory null guard | not applicable | Android classes. |
| 20 | Pin limit double counting on folder tabs, crash fixes in Android list adapters | not applicable | Android UI code. |
| 21 | Photo editing and sharing fixes (crop from source, motion photos, caption lost, album stale group) | not applicable | Android media editor and SendMessagesHelper; iOS uses its own editor and has no motion-photo path. |
| 22 | mdesktop admin log use-after-free, export -Wtype-limits, Windows submenu, folder slide with no area | not applicable | tdesktop / Qt code. |
| 23 | mdesktop: collapsed community members must not match type folders (Groups, Channels) | open | iOS `chatListFilterPredicate` treats a community row as one entry (excluded when Groups is off). Whether members of a collapsed community can also match needs a device with communities. No change. |
| 24 | Search operators (from:, before:, after:, date:, type:) | ported (feature, section 7) | `submodules/NanogramFeatures`, `docs/specs/search-operators.md`. Mercurygram Android commits (MgSearchQuery group): 291b1c0ab, 61ed3f602, 94efecb78, 0884e7357. |
| 25 | Tracking-parameter stripping, confirm t.me links | ported (feature, section 7) | `LinkHygiene`, Settings > Nanogram Features. Mercurygram Android commits (MgUrlCleaner / toggles group): 0ec92ad56, 38dbb8733, 197a708ae, 7c876bb07. |
| 26 | Decorated-Unicode folding for local chat search | not in scope | A feature, not a bug fix or performance item (section 9 covers fixes). |
| 27 | PFS temp-key ladder, CDN redirect refusal, local drafts, link previews off, global search off | declined | Change what the server sees (owner rule). |
| 28 | Premium/ads gates, Tor, GMS/Firebase removal, UnifiedPush, reproducible-build flags | declined | Owner exclusions. |
