# In-chat search operators (shared grammar, iOS / Mac / Android)

Owner decision 2026-11-14 (diagnostics-and-debug-round2 section 7). The iOS repo owns this file; the Mac and Android
apps implement the same grammar. The idea comes from Mercurygram (GPL-2.0); the grammar below is written from the
behaviour, not copied from code. Tracking-parameter data for link hygiene lives next to it in
[link-tracking-params.txt](link-tracking-params.txt).

## Where it applies

- The search field inside one chat (and a topic or thread of it). Not the chat-list search, not global search.
- Toggle "Search operators" in Settings > Nanogram features, default ON. When off, the query goes out unchanged.
- Secret chats search locally and have no server filters: the operators are not applied there.

## Grammar

The query is split on whitespace into tokens. A token is an operator token when it is `name:value` with a known
`name` (case-insensitive) and a non-empty value that parses. Everything else is plain text, kept in its original order
and joined with single spaces. A token that does not parse (unknown name, empty value, bad date, unknown type) stays
plain text, so nothing is silently widened or dropped.

A value may be wrapped in double quotes to hold spaces (`from:"Jane Doe"`). An unclosed quote makes the token plain.

| Operator | Value | Maps to |
| --- | --- | --- |
| `from:` | `@username`, `username` or `me` | `from_id` (the sender). `me` is the signed-in account. A name that does not resolve leaves the token as plain text. How a name resolves is up to the platform: iOS resolves public usernames and `me` only, so a quoted display name stays plain text there; Mac and Android may also match chat members by display name. While a lookup runs, the search runs without the sender and repeats once it resolves. |
| `before:` | date | `max_date`: messages strictly before the start of that day |
| `after:` | date | `min_date`: messages from the start of the day after that date onward |
| `date:` | date | `min_date` = start of that day, `max_date` = start of the next day |
| `type:` | type name | one `MessagesFilter` |

Dates (local time zone of the device, days run 00:00 to 24:00):

- `YYYY-MM-DD`, `YYYY-MM` (the whole month), `YYYY` (the whole year), `today`, `yesterday`.
- For `before:` the start of the first day of the range is used, for `after:` the end of the last day of the range, for
  `date:` the whole range. So `date:2026-11` is all of November, `before:2026-11` is before 1 Nov, `after:2026-11` is from 1 Dec.
- Digits only, four-digit year from 1970 to 2100, real calendar dates only (no `2026-02-30`).

Types (`type:` value, case-insensitive) and their filter:

| Value | Filter |
| --- | --- |
| `photo` | photos |
| `video` | videos |
| `file` | documents |
| `link` | URLs |
| `voice` | voice messages |
| `music` | audio |
| `gif` | GIFs |
| `round` | round videos |
| `poll` | polls |
| `pinned` | pinned messages |
| `contact` | contacts |
| `geo` | locations |
| `mention` | messages mentioning you |

A platform leaves a type as plain text when its search has no such filter. iOS: `contact`, `geo` and `mention` are
not available in the iOS search (no tag for them), so on iOS those three stay plain text. Mac and Android follow
their own filter sets and say so in their changelog.

Repeated operators: the last one wins (`before:` twice uses the second). The earlier token is still consumed, not
left in the text. When `date:` is combined with `before:`/`after:`, the tighter bound of each side wins.

When the text is empty after removing operators, the search still runs with the filters alone (for example
`from:@jane` lists everything Jane sent). A `type:` filter together with `from:` is sent as one request when the
platform supports it; iOS sends `from_id`, `min_date`, `max_date` and the tag together.

## Test vectors (all platforms must produce these; "now" is 2026-11-14 12:00 local)

| Input | Plain text | from | min | max | type |
| --- | --- | --- | --- | --- | --- |
| `hello` | `hello` | | | | |
| `hello from:@jane` | `hello` | jane | | | |
| `from:"Jane Doe" x` | `x` | Jane Doe (parser output; resolution is per platform) | | | |
| `before:2026-11-01` | | | | 2026-11-01 00:00 | |
| `after:2026-11-01` | | | 2026-11-02 00:00 | | |
| `date:2026-11-01` | | | 2026-11-01 00:00 | 2026-11-02 00:00 | |
| `date:2026-11` | | | 2026-11-01 00:00 | 2026-12-01 00:00 | |
| `date:today` | | | 2026-11-14 00:00 | 2026-11-15 00:00 | |
| `date:yesterday report` | `report` | | 2026-11-13 00:00 | 2026-11-14 00:00 | |
| `type:photo cat` | `cat` | | | | photo |
| `TYPE:Photo` | | | | | photo |
| `type:banana` | `type:banana` | | | | |
| `date:2026-02-30` | `date:2026-02-30` | | | | |
| `from:` | `from:` | | | | |
| `before:2026-11-01 before:2026-10-01` | | | | 2026-10-01 00:00 | |
| `from:"Jane` | `from:"Jane` | | | | |
| `https://x.test/a:b` | `https://x.test/a:b` | | | | |

## Help line

Shown under the toggle: `Operators: from:, before:, after:, date:, type: (photo, video, file, link, voice, music, gif, round, poll, pinned).`
Each platform trims the type list to what it supports.

## Link hygiene (same Nanogram features screen)

- Strip known tracking parameters from a link when it is OPENED and when it is COPIED (link menu, copy link, share
  sheet link copy). The list is the data file [link-tracking-params.txt](link-tracking-params.txt) (exact names,
  `prefix*` entries and per-host entries). Parameters not in the list are never touched; the order of the others and
  the fragment stay as they are; a link without a query is returned unchanged.
- Never rewrite outgoing message text or the text of a message already shown.
- Optional "Confirm before opening Telegram links": a confirmation sheet before a `t.me` / `telegram.me` /
  `telegram.dog` link (with or without `www.`) or a `tg://` link opens. `telesco.pe` and a bare `tg:` (no `//`) do not
  count. Empty query items (`a=1&&b=2`) are kept when something else is removed. The iOS and Mac apps compile the
  same source (`submodules/NanogramFeatures`; the Mac keeps only its settings-toggle glue).
- Toggles: "Remove tracking from links" and "Confirm Telegram links", both default OFF.
