# Background diagnostic and the lock task

## Background diagnostic and the "lock" task

With Settings ▸ Debug "Log to File" on, the app logs a `Background diagnostic:` line 5 s and 60 s after entering
the background (`BackgroundDiagnostics` module, `AppDelegate.logBackgroundDiagnostics`): footprint by kind
(`task_vm_info`: internal, compressed, graphics, media, purgeable, malloc), background time remaining, the background
tasks the app holds, whether the audio session is active, display links, and cache sizes. `after` far above the
scheduled time means the process was suspended in between. Nothing leaves the device. The "lock" task begun on
entering the background is a `OneShotBackgroundTask`: ended once, by its 5 s deadline or the expiration handler.

**Database writes stop before the app lets iOS suspend it (0xdead10cc).** The account databases are in the shared
app-group container, and a suspended app holding their SQLite lock is killed (MetricKit `fileLock`). So every
background task the app ends in the background (the "lock" task's 5 s deadline, `SharedWakeupManager`'s
"background-wakeup", "explicit-extension" and "transaction-window" tasks), every push/background-fetch completion
handler it calls, and every `BGContinuedProcessingTask` it completes goes through
`SharedWakeupManager.releaseBackgroundTime`, after the state that held it was dropped and `checkTasks` ran. Unless
writes stay enabled (something else keeps the app awake), it pauses transactions and ends the task once the running
one committed, or after `BackgroundTaskRelease.drainTimeout` at the latest: until 2 s before
`backgroundTimeRemaining` runs out, at least 1 s, at most 25 s (3 s for a push/fetch completion or a BG task, whose
deadline is its own, and when the value is DBL_MAX). A fixed 3 s cap ended the "explicit-extension" task under a
background transaction that ran longer (chat-list replay reading peer data from disk after `clearCaches()`), and iOS
killed the suspended app (`fileLock`, 24 Nov 2026). The 2 s margin matters: once the 20 s timer fired, that task's
expiration handler does nothing, so a task still held at expiration would be a task-timeout kill.
`allowBackgroundTimeExtension`'s
2 s window holds its own "transaction-window" task, because it re-enables transactions (and runs the queued ones)
on a push whose completion handler may be called at once. Calling `endBackgroundTask` or a completion directly
there brings the crash back. The order is pinned by `BackgroundTaskReleaseTests` (host test,
`//submodules/BackgroundDiagnostics:BackgroundDiagnosticsTests`). The notification service and share extensions
hold a `performExpiringActivity` instead (`ExtensionRequestCompletion`, `ShareProcessActivity`).

**Writes stay enabled only while a task was granted.** `beginBackgroundTask` can return `.invalid`; then the
"explicit-extension" 20 s timer is not started and "background-wakeup" is not held, because both keep writes enabled
(`updateAccounts`) and an invalid id keeps nothing awake. When the audio session ends in the background (audio kept
writes enabled), a short "audio-end-drain" task is held through `releaseBackgroundTime`, so the running transaction
commits before iOS can suspend the app.

**Short-log lines** (written with "Log to File" off, so a background kill explains itself): `Wakeup: app
background/foreground`; `enableBeginTransactions: true (<holders>)` / `false` on each change; `background task <name>
not granted (invalid)`; `explicit-extension not granted`; and `drain timeout after <s> s (remaining at release <s> s):
writes not paused, running: <file:line> for <ms> ms`, logged just before the task ends (the end flushes the logs).
The running transaction comes from `Postbox.runningTransaction()`, an atomic read that does not wait for the busy
Postbox queue.
