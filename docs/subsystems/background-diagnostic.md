# Background diagnostic and the lock task

## Background diagnostic and the "lock" task

With Settings ▸ Debug "Log to File" on, the app logs a `Background diagnostic:` line 5 s and 60 s after entering
the background (`BackgroundDiagnostics` module, `AppDelegate.logBackgroundDiagnostics`): footprint by kind
(`task_vm_info`: internal, compressed, graphics, media, purgeable, malloc), background time remaining, the background
tasks the app holds, whether the audio session is active, display links, and cache sizes. `after` far above the
scheduled time means the process was suspended in between. Nothing leaves the device. The "lock" task begun on
entering the background is a `OneShotBackgroundTask`: ended once, by its 5 s deadline or the expiration handler.

**Memory in the short log, whatever "Log to File" says.** "Log to File" is off by default on TestFlight, so the file
log's memory lines (the 30 s `Memory detail:`, `Memory purge`, the background diagnostic) are usually missing from
testers' reports. A compact `Memory <reason>:` line (`MemoryShortLogLine`: footprint before/after for a purge, peak,
malloc, compressed, graphics, headroom, the largest malloc zone and its block count; at most 256 bytes) goes to
`Logger.shortLog` (the `critlog-*` files) at launch, on entering the background and on a memory warning (each at
most once a minute), and every 10 minutes at most while the footprint is above 1 GB (`MemoryShortLogBudget`, pinned
by `MemoryShortLogTests`). That is at most a few hundred lines a day, against tens of thousands of network and
Postbox lines. A purge's "after" is measured right after `malloc_zone_pressure_relief`; the Postbox caches are
cleared later on their own queue, so their release shows in the next line, not in that one.

**Database writes stop before the app lets iOS suspend it (0xdead10cc).** The account databases are in the shared
app-group container, and a suspended app holding their SQLite lock is killed (MetricKit `fileLock`). So every
background task the app ends in the background (the "lock" task's 5 s deadline, `SharedWakeupManager`'s
"background-wakeup", "explicit-extension" and "transaction-window" tasks), every push/background-fetch completion
handler it calls, and every `BGContinuedProcessingTask` it completes goes through
`SharedWakeupManager.releaseBackgroundTime`, after the state that held it was dropped and `checkTasks` ran. Unless
writes stay enabled (something else keeps the app awake), it pauses transactions and ends the task once the running
one committed, or after `BackgroundTaskRelease.drainTimeout` (1-3 s) at the latest. `allowBackgroundTimeExtension`'s
2 s window holds its own "transaction-window" task, because it re-enables transactions (and runs the queued ones)
on a push whose completion handler may be called at once. Calling `endBackgroundTask` or a completion directly
there brings the crash back. The order is pinned by `BackgroundTaskReleaseTests` (host test,
`//submodules/BackgroundDiagnostics:BackgroundDiagnosticsTests`). The notification service and share extensions
hold a `performExpiringActivity` instead (`ExtensionRequestCompletion`, `ShareProcessActivity`).
