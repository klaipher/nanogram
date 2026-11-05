# Timers and wake-ups

## Timers and wake-ups (SwiftSignalKit, Network.framework keepalive)

- **`SwiftSignalKit.Timer` has leeway by default.** Timeouts of 1 s or longer get
  `min(10% of the timeout, 1 s)` (`TimerLeeway.automatic`), so the kernel can fire them together
  with other wake-ups (Mac benchmark, 40 staggered 1-5 s repeating timers: 15.1 -> 4.3 wake-ups/s).
  `delay()`/`timeout()` inherit it. Pass `leeway: .precise` for any timer the user can see:
  count-downs, recording and playback timers, animation loops, gestures (long press), typing
  indicators, and timers that show or hide UI. A new visible timer without it can tick up to 1 s late.
  Legacy (`SwiftSignalKit/Source`, iOS) and v2 (`SwiftSignalKit2/Source`, macOS SwiftPM) must keep
  the same API; the shared `SwiftSignalKitTesting/Behavior` tests compile against both.
- **`suspendAwareDelay` is one wall-clock deadline** (`DispatchWallTime`, `granularity` as leeway)
  in both libraries. Do not reintroduce a repeating check: ~45 per-account pollers sit in hour-long
  delays and the old 4 s loop caused most background wake-ups (`Stress/IdleWakeupTests`, 2362 -> 10
  wake-ups/s with 200 pending delays).
- **Network.framework TCP keepalive is 30 s idle / 10 s interval / 3 probes**
  (`configureNetworkFrameworkTcpOptions`, was 5/5/2). Dead connections are also caught by the
  viability handler and MTProto pings (the better-path handler is still commented out). Before
  tuning it further, or if reconnects look slower, run the device check from the 2026-11 deep audit:
  Power Profiler on cellular, 5 min idle with the old and new values, and time a reconnect after a
  Wi-Fi to cellular switch for each.
