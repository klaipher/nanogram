#import <MtProtoKit/MTApiEnvironment.h>

#if TARGET_OS_IPHONE
#   import <UIKit/UIKit.h>
#else

#endif

#include <sys/sysctl.h>

#import <CommonCrypto/CommonDigest.h>

static NSData * _Nullable parseHexString(NSString * _Nonnull hex) {
    if ([hex length] % 2 != 0) {
        return nil;
    }
    char buf[3];
    buf[2] = '\0';
    uint8_t *bytes = (uint8_t *)malloc(hex.length / 2);
    uint8_t *bp = bytes;
    for (CFIndex i = 0; i < [hex length]; i += 2) {
        buf[0] = [hex characterAtIndex:i];
        buf[1] = [hex characterAtIndex:i+1];
        char *b2 = NULL;
        *bp++ = strtol(buf, &b2, 16);
        if (b2 != buf + 2) {
            free(bytes);
            return nil;
        }
    }
    
    return [NSData dataWithBytesNoCopy:bytes length:[hex length]/2 freeWhenDone:YES];
}

static NSString * _Nonnull dataToHexString(NSData * _Nonnull data) {
    const unsigned char *dataBuffer = (const unsigned char *)[data bytes];
    if (dataBuffer == NULL) {
        return @"";
    }
    
    NSUInteger dataLength  = [data length];
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    
    for (int i = 0; i < (int)dataLength; ++i) {
        [hexString appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)dataBuffer[i]]];
    }
    
    return hexString;
}

static NSData *base64_decode(NSString *str) {
    if ([NSData instancesRespondToSelector:@selector(initWithBase64EncodedString:options:)]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:NSDataBase64DecodingIgnoreUnknownCharacters];
        return data;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [[NSData alloc] initWithBase64Encoding:[str stringByReplacingOccurrencesOfString:@"[^A-Za-z0-9+/=]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [str length])]];
#pragma clang diagnostic pop
    }
}

@implementation MTProxySecret

- (instancetype _Nullable)initWithSecret:(NSData * _Nonnull)secret {
    self = [super init];
    if (self != nil) {
        _secret = secret;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self != nil) {
        _secret = [aDecoder decodeObjectForKey:@"secret"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:_secret forKey:@"secret"];
}

+ (MTProxySecret * _Nullable)parse:(NSString * _Nonnull)string {
    NSData *hexData = parseHexString(string);
    if (hexData == nil) {
        NSString *finalString = @"";
        finalString = [finalString stringByAppendingString:[string stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]]];
        finalString = [finalString stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
        finalString = [finalString stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        while (finalString.length % 4 != 0) {
            finalString = [finalString stringByAppendingString:@"="];
        }
        
        hexData = base64_decode(finalString);
    }
    if (hexData != nil) {
        return [self parseData:hexData];
    } else {
        return nil;
    }
}

+ (MTProxySecret * _Nullable)parseData:(NSData * _Nonnull)data {
    if (data == nil || data.length < 16) {
        return nil;
    }
    
    uint8_t firstByte = 0;
    [data getBytes:&firstByte length:1];
    
    if (data.length == 16) {
        return [[MTProxySecretType0 alloc] initWithSecret:data];
    } else if (data.length == 17) {
        if (firstByte == 0xdd) {
            return [[MTProxySecretType1 alloc] initWithSecret:[data subdataWithRange:NSMakeRange(1, 16)]];
        } else {
            return nil;
        }
    } else if (data.length >= 18 && firstByte == 0xee) {
        NSString *domain = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(1 + 16, data.length - (1 + 16))] encoding:NSUTF8StringEncoding];
        if (domain == nil) {
            return nil;
        }
        return [[MTProxySecretType2 alloc] initWithSecret:[data subdataWithRange:NSMakeRange(1, 16)] domain:domain];
    } else {
        return nil;
    }
}

- (NSData * _Nonnull)serialize {
    assert(false);
    return nil;
}

- (NSString * _Nonnull)serializeToString {
    assert(false);
    return nil;
}

- (NSString *)description {
    return dataToHexString([self serialize]);
}

@end

@implementation MTProxySecretType0

- (instancetype _Nullable)initWithSecret:(NSData * _Nonnull)secret {
    self = [super initWithSecret:secret];
    if (self != nil) {
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self != nil) {
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
}

- (NSData * _Nonnull)serialize {
    return self.secret;
}

- (NSString * _Nonnull)serializeToString {
    return dataToHexString(self.serialize);
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MTProxySecretType0 class]]) {
        return false;
    }
    MTProxySecretType0 *other = object;
    if (![self.secret isEqual:other.secret]) {
        return false;
    }
    return true;
}

@end

@implementation MTProxySecretType1

- (instancetype _Nullable)initWithSecret:(NSData * _Nonnull)secret {
    self = [super initWithSecret:secret];
    if (self != nil) {
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self != nil) {
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
}

- (NSData * _Nonnull)serialize {
    NSMutableData *data = [[NSMutableData alloc] init];
    uint8_t marker = 0xdd;
    [data appendBytes:&marker length:1];
    [data appendData:self.secret];
    return data;
}

- (NSString * _Nonnull)serializeToString {
    return dataToHexString(self.serialize);
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MTProxySecretType1 class]]) {
        return false;
    }
    MTProxySecretType1 *other = object;
    if (![self.secret isEqual:other.secret]) {
        return false;
    }
    return true;
}

@end

@implementation MTProxySecretType2

- (instancetype _Nullable)initWithSecret:(NSData * _Nonnull)secret domain:(NSString * _Nonnull)domain {
    self = [super initWithSecret:secret];
    if (self != nil) {
        _domain = domain;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self != nil) {
        _domain = [aDecoder decodeObjectForKey:@"domain"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
    [aCoder encodeObject:_domain forKey:@"domain"];
}

- (NSData * _Nonnull)serialize {
    NSMutableData *data = [[NSMutableData alloc] init];
    uint8_t marker = 0xee;
    [data appendBytes:&marker length:1];
    [data appendData:self.secret];
    [data appendData:[_domain dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

- (NSString * _Nonnull)serializeToString {
    NSData *data = [self serialize];
    NSString *result = [data base64EncodedStringWithOptions:kNilOptions];
    result = [result stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    result = [result stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    result = [result stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return result;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MTProxySecretType2 class]]) {
        return false;
    }
    MTProxySecretType2 *other = object;
    if (![self.secret isEqual:other.secret]) {
        return false;
    }
    if (![self.domain isEqual:other.domain]) {
        return false;
    }
    return true;
}

@end

@implementation MTSocksProxySettings

- (instancetype)initWithIp:(NSString *)ip port:(uint16_t)port username:(NSString *)username password:(NSString *)password secret:(NSData *)secret {
    return [self initWithIp:ip port:port username:username password:password secret:secret webProxy:false];
}

- (instancetype)initWithIp:(NSString *)ip port:(uint16_t)port username:(NSString *)username password:(NSString *)password secret:(NSData *)secret webProxy:(bool)webProxy {
    self = [super init];
    if (self != nil) {
        _ip = ip;
        _port = port;
        _username = username;
        _password = password;
        _secret = secret;
        _webProxy = webProxy;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MTSocksProxySettings class]]) {
        return false;
    }
    MTSocksProxySettings *other = object;
    if ((other->_ip != nil) != (_ip != nil) || (_ip != nil && ![_ip isEqual:other->_ip])) {
        return false;
    }
    if (other->_port != _port) {
        return false;
    }
    if ((other->_username != nil) != (_username != nil) || (_username != nil && ![_username isEqual:other->_username])) {
        return false;
    }
    if ((other->_password != nil) != (_password != nil) || (_password != nil && ![_password isEqual:other->_password])) {
        return false;
    }
    if ((other->_secret != nil) != (_secret != nil) || (_secret != nil && ![_secret isEqual:other->_secret])) {
        return false;
    }
    if (other->_webProxy != _webProxy) {
        return false;
    }
    return true;
}

- (NSString *)description {
    if (_webProxy) {
        return [NSString stringWithFormat:@"%@:%d+web", _ip, (int)_port];
    }
    return [NSString stringWithFormat:@"%@:%d+%@+%@+%@", _ip, (int)_port, _username, _password, [_secret description]];
}

@end

@implementation MTNetworkSettings

- (instancetype)initWithReducedBackupDiscoveryTimeout:(bool)reducedBackupDiscoveryTimeout {
    self = [super init];
    if (self != nil) {
        _reducedBackupDiscoveryTimeout = reducedBackupDiscoveryTimeout;
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MTNetworkSettings class]]) {
        return false;
    }
    MTNetworkSettings *other = object;
    if (_reducedBackupDiscoveryTimeout != other->_reducedBackupDiscoveryTimeout) {
        return false;
    }
    return true;
}

@end

@implementation MTApiEnvironment

-(instancetype)init {
    self = [self initWithDeviceModelName:nil];
    if (self != nil)
    {
        
    }
    return self;
}

-(id _Nonnull)initWithDeviceModelName:(NSString * _Nullable)deviceModelName {
    self = [super init];
    if (self != nil)
    {
        if (deviceModelName != nil) {
            _deviceModel = deviceModelName;
        } else {
            _deviceModel = [self platformString];
        }
        _deviceModelName = deviceModelName;
#if TARGET_OS_IPHONE
        _systemVersion = [MTApiEnvironment majorSystemVersion:[[UIDevice currentDevice] systemVersion]];
#else
        NSProcessInfo *pInfo = [NSProcessInfo processInfo];
        _systemVersion = [MTApiEnvironment majorSystemVersion:[[[pInfo operatingSystemVersionString] componentsSeparatedByString:@" "] objectAtIndex:1]];
#endif
        
NSString *suffix = @"";
#if TARGET_OS_OSX
        NSString *value = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"SOURCE"];
        if (value != nil) {
            suffix = [NSString stringWithFormat:@"%@", value];
        }
#endif
        
        //SOURCE
        NSString *versionString = [[NSString alloc] initWithFormat:@"%@ (%@) %@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"], [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"], suffix];
        _appVersion = versionString;
        
        _systemLangCode = [MTApiEnvironment languageCodeWithoutRegion:[[NSLocale preferredLanguages] firstObject]];
    #if TARGET_OS_OSX
        _langPack = @"macos";
    #else
         _langPack = @"ios";
    #endif
        _langPackCode = @"";
        
        [self _updateApiInitializationHash];
    }
    return self;
}

- (void)_updateApiInitializationHash {
    _apiInitializationHash = [[NSString alloc] initWithFormat:@"apiId=%" PRId32 "&deviceModel=%@&systemVersion=%@&appVersion=%@&langCode=%@&layer=%@&langPack=%@&langPackCode=%@&proxy=%@&systemCode=%@", _apiId, _deviceModel, _systemVersion, _appVersion, _systemLangCode, _layer, _langPack, _langPackCode, _socksProxySettings, _systemCode];
}

- (void)setLayer:(NSNumber *)layer {
    _layer = layer;
    
    [self _updateApiInitializationHash];
}

- (void)setAppVersion:(NSString *)appVersion {
    _appVersion = appVersion;
    
    [self _updateApiInitializationHash];
}

- (void)setLangPack:(NSString *)langPack {
    _langPack = langPack;
    
    [self _updateApiInitializationHash];
}

- (void)setLangPackCode:(NSString *)langPackCode {
    _langPackCode = langPackCode;
    
    [self _updateApiInitializationHash];
}

/// The device model sent to Telegram is only the product family. The server shows it in the session
/// list and does not need the exact hardware (an iPhone 16 Pro Max is just "iPhone").
+ (NSString *)deviceFamilyNameForHardwareIdentifier:(NSString *)hardwareIdentifier {
    if ([hardwareIdentifier hasPrefix:@"iPad"]) {
        return @"iPad";
    }
    if ([hardwareIdentifier hasPrefix:@"iPhone"] || [hardwareIdentifier hasPrefix:@"iPod"]) {
        return @"iPhone";
    }
    if ([hardwareIdentifier hasPrefix:@"Mac"] || [hardwareIdentifier hasPrefix:@"iMac"]) {
        return @"Mac";
    }
    return nil;
}

/// "18.2.1" -> "18". Only the major system version leaves the device.
+ (NSString *)majorSystemVersion:(NSString *)systemVersion {
    NSString *major = [[systemVersion componentsSeparatedByString:@"."] firstObject];
    if (major.length == 0) {
        return systemVersion ?: @"";
    }
    return major;
}

/// "en-US" -> "en", "zh-Hans-CN" -> "zh-Hans". The region never leaves the device.
+ (NSString *)languageCodeWithoutRegion:(NSString *)identifier {
    if (identifier.length == 0) {
        return @"en";
    }
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:identifier];
    NSString *language = locale.languageCode;
    if (language.length == 0) {
        return @"en";
    }
    NSString *script = locale.scriptCode;
    if (script.length != 0) {
        return [NSString stringWithFormat:@"%@-%@", language, script];
    }
    return language;
}

- (NSString *)platformString
{
#if TARGET_OS_IPHONE
    NSString *family = [MTApiEnvironment deviceFamilyNameForHardwareIdentifier:[self platform]];
    if (family != nil) {
        return family;
    }
    return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
#else
    return @"Mac";
#endif
}

- (NSString *)getSysInfoByName:(char *)typeSpecifier
{
    size_t size;
    sysctlbyname(typeSpecifier, NULL, &size, NULL, 0);
    
    char *answer = malloc(size);
    sysctlbyname(typeSpecifier, answer, &size, NULL, 0);
    
    NSString *results = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
    
    free(answer);
    return results;
}

- (NSString *)platform
{
    return [self getSysInfoByName:"hw.machine"];
}

- (MTApiEnvironment *)withUpdatedLangPackCode:(NSString *)langPackCode {
    MTApiEnvironment *result = [[MTApiEnvironment alloc] initWithDeviceModelName:_deviceModelName];
    
    result.apiId = self.apiId;
    result.appVersion = self.appVersion;
    result.layer = self.layer;
    
    result.langPack = self.langPack;
    
    result->_langPackCode = langPackCode;
    
    result.disableUpdates = self.disableUpdates;
    result.tcpPayloadPrefix = self.tcpPayloadPrefix;
    result.datacenterAddressOverrides = self.datacenterAddressOverrides;
    result.accessHostOverride = self.accessHostOverride;
    result->_socksProxySettings = self.socksProxySettings;
    result->_networkSettings = self.networkSettings;
    result->_systemCode = self.systemCode;
    
    [result _updateApiInitializationHash];
    
    return result;
}

- (instancetype)copyWithZone:(NSZone *)__unused zone {
    MTApiEnvironment *result =  [[MTApiEnvironment alloc] initWithDeviceModelName:_deviceModelName];
    
    result.apiId = self.apiId;
    result.appVersion = self.appVersion;
    result.layer = self.layer;
    
    result.langPack = self.langPack;
    
    result->_langPackCode = self.langPackCode;
    result->_socksProxySettings = self.socksProxySettings;
    result->_networkSettings = self.networkSettings;
    result->_systemCode = self.systemCode;
    
    result.disableUpdates = self.disableUpdates;
    result.tcpPayloadPrefix = self.tcpPayloadPrefix;
    result.datacenterAddressOverrides = self.datacenterAddressOverrides;
    result.accessHostOverride = self.accessHostOverride;
    
    [result _updateApiInitializationHash];
    
    return result;
}

- (MTApiEnvironment *)withUpdatedSocksProxySettings:(MTSocksProxySettings *)socksProxySettings {
    MTApiEnvironment *result =  [[MTApiEnvironment alloc] initWithDeviceModelName:_deviceModelName];
    
    result.apiId = self.apiId;
    result.appVersion = self.appVersion;
    result.layer = self.layer;
    
    result.langPack = self.langPack;
    
    result->_langPackCode = self.langPackCode;
    result->_socksProxySettings = socksProxySettings;
    result->_networkSettings = self.networkSettings;
    result->_systemCode = self.systemCode;
    
    result.disableUpdates = self.disableUpdates;
    result.tcpPayloadPrefix = self.tcpPayloadPrefix;
    result.datacenterAddressOverrides = self.datacenterAddressOverrides;
    result.accessHostOverride = self.accessHostOverride;
    
    [result _updateApiInitializationHash];
    
    return result;
}

- (MTApiEnvironment *)withUpdatedNetworkSettings:(MTNetworkSettings *)networkSettings {
    MTApiEnvironment *result =  [[MTApiEnvironment alloc] initWithDeviceModelName:_deviceModelName];
    
    result.apiId = self.apiId;
    result.appVersion = self.appVersion;
    result.layer = self.layer;
    
    result.langPack = self.langPack;
    
    result->_langPackCode = self.langPackCode;
    result->_socksProxySettings = self.socksProxySettings;
    result->_networkSettings = networkSettings;
    result->_systemCode = self.systemCode;
    
    result.disableUpdates = self.disableUpdates;
    result.tcpPayloadPrefix = self.tcpPayloadPrefix;
    result.datacenterAddressOverrides = self.datacenterAddressOverrides;
    result.accessHostOverride = self.accessHostOverride;
    
    [result _updateApiInitializationHash];
    
    return result;
}

- (MTApiEnvironment *)withUpdatedSystemCode:(NSData *)systemCode {
    MTApiEnvironment *result =  [[MTApiEnvironment alloc] initWithDeviceModelName:_deviceModelName];
    
    result.apiId = self.apiId;
    result.appVersion = self.appVersion;
    result.layer = self.layer;
    
    result.langPack = self.langPack;
    
    result->_langPackCode = self.langPackCode;
    result->_socksProxySettings = self.socksProxySettings;
    result->_networkSettings = self.networkSettings;
    result->_systemCode = systemCode;
    
    result.disableUpdates = self.disableUpdates;
    result.tcpPayloadPrefix = self.tcpPayloadPrefix;
    result.datacenterAddressOverrides = self.datacenterAddressOverrides;
    result.accessHostOverride = self.accessHostOverride;
    
    [result _updateApiInitializationHash];
    
    return result;
}

@end
