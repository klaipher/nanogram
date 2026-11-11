#import <MtProtoKit/MTLogging.h>

static void (*loggingFunction)(NSString *) = NULL;
static void (*shortLoggingFunction)(NSString *) = NULL;
// Off until the app turns the network protocol dumps on (Debug Settings "Network protocol dumps").
static bool MTLogEnabledValue = false;

bool MTShouldLogMT(MTLogChannel channel, bool verboseEnabled, bool isAppExtension) {
    switch (channel) {
        case MTLogChannelShort:
            return true;
        case MTLogChannelVerbose:
            return verboseEnabled;
        case MTLogChannelContextDump:
            return verboseEnabled && !isAppExtension;
    }
    return false;
}

static bool MTIsAppExtension() {
    static bool value = false;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        value = [[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"];
    });
    return value;
}

bool MTLogEnabled() {
    return loggingFunction != NULL && MTShouldLogMT(MTLogChannelVerbose, MTLogEnabledValue, false);
}

bool MTLogContextDumpEnabled() {
    return loggingFunction != NULL && MTShouldLogMT(MTLogChannelContextDump, MTLogEnabledValue, MTIsAppExtension());
}

void MTLog(NSString *format, ...) {
    va_list L;
    va_start(L, format);
    if (loggingFunction != NULL && MTShouldLogMT(MTLogChannelVerbose, MTLogEnabledValue, false)) {
        NSString *string = [[NSString alloc] initWithFormat:format arguments:L];
        loggingFunction(string);
    }
    va_end(L);
}

void MTLogWithPrefix(NSString *(^getLogPrefix)(), NSString *format, ...) {
    va_list L;
    va_start(L, format);
    if (loggingFunction != NULL && MTShouldLogMT(MTLogChannelVerbose, MTLogEnabledValue, false)) {
        NSString *string = [[NSString alloc] initWithFormat:format arguments:L];
        if (getLogPrefix) {
            NSString *prefix = getLogPrefix();
            if (prefix) {
                string = [prefix stringByAppendingString:string];
            }
        }
        loggingFunction(string);
    }
    va_end(L);
}

void MTShortLog(NSString *format, ...) {
    va_list L;
    va_start(L, format);
    if (shortLoggingFunction != NULL) {
        NSString *string = [[NSString alloc] initWithFormat:format arguments:L];
        shortLoggingFunction(string);
    }
    va_end(L);
}

void MTLogSetLoggingFunction(void (*function)(NSString *)) {
    loggingFunction = function;
}

void MTLogSetShortLoggingFunction(void (*function)(NSString *)) {
    shortLoggingFunction = function;
}

void MTLogSetEnabled(bool enabled) {
    MTLogEnabledValue = enabled;
}
