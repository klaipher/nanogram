# A/B test of three performance experiments (iPhone 14 and iPhone 14 Pro)

For TestFlight testers with an **iPhone 14 / 14 Plus (chip A15)** or an **iPhone 14 Pro / 14 Pro Max (chip A16)**.
No Xcode needed. Plan about 90 minutes in total, spread over a day if you like. The two chips behave differently
under load, so please report which phone you used. Every test is done twice: first with the switch **off** (A),
then with it **on** (B).

Three experiments, each with its own switch:

| Switch (Debug Settings) | What it changes | What you test |
|---|---|---|
| Thread pools on quality of service | Background work (stickers, photo picker) is scheduled by the system's quality classes | Test 3: long scroll |
| AV1 video: several decode threads | AV1 videos decode on more than one thread | Test 1: AV1 video |
| Gallery scrubbing: hardware decode | Scrubbing a big H.264/HEVC video uses the video chip for previews | Test 2: gallery scrubbing |

## 0. Before you start

1. **Check your phone.** Settings > General > About > **Model Name** (and Model Number). Note it. Model Name
   "iPhone 14" or "iPhone 14 Plus" is A15; "iPhone 14 Pro" or "14 Pro Max" is A16. The Debug Settings also show
   it (step 4).
2. Update Nanogram to the newest TestFlight build.
3. **Open the debug menu:** in Nanogram, go to the **Settings** tab and tap the Settings tab icon **10 times quickly**
   (tap about 3 times a second or faster: less than 0.4 s between taps). The "Debug Settings" list opens. It exists in TestFlight builds.
4. Scroll to the section **PERFORMANCE EXPERIMENTS**. It shows three switches (all off at first), your device
   ("iPhone 14 Pro (A16), iPhone15,2") and measured numbers. Check the device line matches your phone.
5. Turn on **Log to File** (top of the Debug Settings) so the logs in the report are saved.
6. Switch off Low Power Mode (it keeps the AV1 experiment at one thread on purpose) and turn on Wi-Fi. Charge
   above 60%. Do not charge during tests. Let the phone cool to normal before each run (not warm to the touch).
7. Close other apps, keep the screen brightness the same for A and B.

## How to switch between A and B

1. Debug Settings > PERFORMANCE EXPERIMENTS > flip the switch you are testing. A message asks you to relaunch.
2. **Force-quit Nanogram** (swipe it away in the app switcher) and open it again. The change only applies after this.
3. Reopen Debug Settings and check that the switch shows what you want. Only one switch on at a time.

Always do **A (off) first, then B (on)**, back to back, same content and same place in the chat. Between A and
B, write down your result before you start the next run.

## Test 1: AV1 video (switch "AV1 video: several decode threads")

Content: an **AV1 video**, 1080p or larger. Telegram does not label codecs, so you cannot recognise AV1 by looking.
Use the test video the project owner sends you before the round (file name starts with `av1-`). If you did
not get one, skip Test 1 and say so in your report.

Script (about 5 minutes per run):
1. Open the video in the chat so it plays full screen. Let it play for 60 seconds.
2. Drag the playback bar back and forth for 20 seconds.
3. Let it play another 60 seconds. Close the video.

Watch for: choppy picture or sound out of sync, the phone getting warm, how long the first picture takes.

## Test 2: Gallery scrubbing (switch "Gallery scrubbing: hardware decode")

Content: a long (more than 3 minutes) H.264 or HEVC video of 4K or 1080p. Most phone-recorded videos are HEVC
(iPhone camera) and fine. Use a video you recorded and sent yourself (for example to Saved Messages), not a channel video with a quality
selector: those use a different preview path that this switch does not change.

Script (about 3 minutes per run):
1. Open the video full screen, pause it.
2. Slowly drag the playback bar from start to end and back, taking about 10 seconds each way. Repeat 3 times.
3. Drag quickly, 5 times, across the whole bar.

After the run, the `scrubPreviewFrame` line in Debug Settings must show n greater than 0. If it says
"no samples", discard the run and repeat with another video.

Watch for: how soon preview pictures follow your finger, blank or wrong previews, any stutter.

## Test 3: Long scroll (switch "Thread pools on quality of service")

Content: a **busy channel or group** with photos, stickers and video stickers (one with thousands of messages).

Script (about 5 minutes per run):
1. Open the chat at the newest message.
2. Scroll up steadily for 2 minutes, flick fast, then slowly.
3. Open the sticker panel, scroll through two sticker packs. Open the photo picker (attach button) and scroll the
   whole grid.
4. Scroll back to the bottom.

Watch for: stutter or blank cells while scrolling, delay before stickers start moving.

## Battery and heat (every run, any test)

Do one 10-minute session per experiment and state (A, B): during it, repeat the test script of that experiment.
- Write down the **battery % before and after** (Settings > Battery, whole percent).
- After the 10 minutes: is the phone **cool / warm / hot** to the touch at the top back?
- A hot phone with a warning from iOS: stop the run and say so.

## What to send

For each experiment and each of A and B send (a message is enough):

- Phone model (Model Name) and iOS version.
- **Smoothness 1 to 5** (5 = perfectly smooth).
- **Stutter:** yes or no (and where).
- **Warm / hot** after the 10 minutes: cool, warm or hot.
- **Battery drop** over the 10 minutes (e.g. 4%).
- **One report:** Settings > **Send Report** (in the help section, next to Ask a Question and Nanogram FAQ), then pick
  Via Nanogram, Via Email or Other Apps. Do it after each run (A and B separately, right after finishing the test,
  **before** flipping the switch and relaunching). The one zip holds everything: phone and app details, the state of each
  switch with the numbers measured since launch (count, average and longest time per frame, preview or waiting task),
  the app and extension logs, call logs, and crash and MetricKit reports. A README inside lists every part. It holds no
  message text and no contacts; phone numbers and emails are masked. Send it to the project owner.

The same numbers show in the grey text under the switches in the Debug Settings (reopen the screen to refresh).

## What the numbers mean

| Line | Meaning | Better |
|---|---|---|
| `threadPoolQueueWait` | how long background tasks wait before starting | lower |
| `av1FrameDecode` | time to decode one AV1 frame | lower |
| `scrubPreviewFrame` | time from scrubbing to the preview picture | lower |

## The decision rule (project owner)

An experiment is turned on by default for a chip only if, over the reports of that chip (A15 and A16 separately,
at least 3 testers each, A15 and A16 decided on their own):

1. median smoothness in B is not lower than in A, and no more testers report stutter in B than in A;
2. the average of its measured time (table above) is at least 15% lower in B in the median export, and its
   longest time is not more than 25% higher;
3. the median battery drop in B is at most 1 percentage point higher than in A, and no tester reports hot in B
   while cool or warm in A.

If it passes on one chip only, it ships for that chip only where the code can tell chips apart; otherwise it stays
off. If it fails any rule, it stays off and the switch is removed in a later build. With too few reports the test is
repeated in the next build.
