# Composer harness

## Composer harness (`Tests/ComposerHarness`)

A standalone, loginless Bazel `ios_application` that hosts the **real** chat composer —
`ChatTextInputPanelNode` → `RichTextEditorChatInputNode` → `RichTextEngineEditorView` — against a
synthetic `AccountContext` whose only non-stubbed part is a genuine `Account` over a disposable
Postbox with networking off. It exists so an agent can drive composer operation on a deterministic
surface and turn each defect into a regression test, without a login and without touching the
logged-in Telegram on K3.

Its own [`CLAUDE.md`](Tests/ComposerHarness/CLAUDE.md) is the operating manual (build/test/run,
the scenario registry, the model-dump contract, which test tier a regression belongs in, and the
simulator-driving hazards).
Two things to know before using it: **height and inset findings are provisional** (the harness has
no `ChatControllerNode` keyboard machinery), and **unprovided app-context members trap and name
themselves** rather than returning a plausible constant.
