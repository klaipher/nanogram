

#ifndef MTLogging_H
#define MTLogging_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Which of the logging channels a line belongs to.
/// - MTLogChannelShort: the short lines (`MTShortLog`), always kept.
/// - MTLogChannelVerbose: MTLog: request/response dumps and the like, only while the dumps are enabled.
/// - MTLogChannelContextDump: the datacenter, scheme-stats and key-info dumps MTContext prints when it loads its keychain;
///   also off in an app extension (the notification service loads a context on every push).
typedef NS_ENUM(NSInteger, MTLogChannel) {
    MTLogChannelShort = 0,
    MTLogChannelVerbose = 1,
    MTLogChannelContextDump = 2
};

/// Pure decision behind every log guard.
bool MTShouldLogMT(MTLogChannel channel, bool verboseEnabled, bool isAppExtension);

bool MTLogEnabled();
/// For the MTContext dumps: MTLogEnabled() and not running in an app extension.
bool MTLogContextDumpEnabled();
void MTLog(NSString *format, ...);
void MTLogWithPrefix(NSString *(^getLogPrefix)(), NSString *format, ...);
void MTShortLog(NSString *format, ...);
void MTLogSetLoggingFunction(void (*function)(NSString *));
void MTLogSetShortLoggingFunction(void (*function)(NSString *));
void MTLogSetEnabled(bool);

#ifdef __cplusplus
}
#endif

#endif
