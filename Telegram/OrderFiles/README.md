# Launch order files

One file per framework, passed to the linker with `-order_file` in release builds only
(`Telegram/BUILD`). They list, in order, the functions that run while the app launches, so the
linker places them next to each other: a cold launch then touches fewer pages of the binary.

The lists come from sampling real launches with Instruments ("App Launch", 1 ms samples), so
they cover the hot path of launch rather than every function. Names the linker cannot find
are ignored, so a stale list never breaks the build; it only lays out less of the launch.

Regenerate after large changes to the launch path (logged-in simulator app installed):

```sh
python3 tools/dev/orderfile.py --udid <SIMULATOR_UDID> --runs 3
```

Generated 2026-11-08 from 3 debug-simulator launches of the Telegram 13.2 merge (main 569510a4): TelegramUI
1,862 symbols, TelegramCore 1,735, Postbox 1,245, SwiftSignalKit 261, MtProtoKit 235 (66/28/22/6/0 profiled
names not found). Against the release binary of build 202611080941 (lists that survive inlining): TelegramUI
1,224 (the 2026-10-31 list: 882), TelegramCore 1,122 (992), Postbox 821 (772), SwiftSignalKit 174 (138),
MtProtoKit 221 (115). About a third of a list never matches a release binary: small functions are inlined there.
The launch-time gain shows on a device (cold launch from flash), not on the simulator.
