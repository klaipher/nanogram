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

Generated 2026-10-31 from 2 debug-simulator launches: TelegramUI 1,485 symbols, TelegramCore
1,578, Postbox 1,201, SwiftSignalKit 202, MtProtoKit 121 (93-99% of profiled names matched).
The launch-time gain shows on a device (cold launch from flash), not on the simulator.
