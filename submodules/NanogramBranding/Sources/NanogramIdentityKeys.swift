/// The strings in which "Telegram" names this app rather than the network.
///
/// Rule: say Nanogram where the string is about this app (its permissions, passcode, cache,
/// updates, extensions, the welcome screen, the in-app browser). Keep Telegram where it names
/// the network, its servers, staff or products (Premium, Stars, Passport, Gifts, Ads, "Telegram
/// account", "Telegram cloud", FAQ, Support, terms, telegram.org and t.me links), as Telegram's
/// API terms (2.2) require.
///
/// tools/dev/lint/branding.py reads both lists between their BEGIN/END markers and
/// checks that every key exists in Telegram/Telegram-iOS/en.lproj/Localizable.strings and that
/// none of the identity values there still names Telegram. Keep one quoted key per line.
enum NanogramIdentityKeys {
    /// Every "Telegram" in these values becomes "Nanogram", in every language
    /// (`NanogramBranding.tokens`), except inside a protected phrase. Plural forms are matched
    /// by suffix (`Key_1`, `Key_any`, ...).
    static let identityKeys: [String] = [
        // BEGIN identity keys
        // Welcome screen.
        "Tour.Title1",
        "Tour.Text2",
        "Tour.Text3",
        "Tour.Text4",
        "Tour.Text5",
        "Tour.Text6",
        // System permissions.
        "AccessDenied.AgeVerificationCamera",
        "AccessDenied.CallMicrophone",
        "AccessDenied.Camera",
        "AccessDenied.CameraRestricted",
        "AccessDenied.Contacts",
        "AccessDenied.LocationAlwaysDenied",
        "AccessDenied.LocationDenied",
        "AccessDenied.LocationDisabled",
        "AccessDenied.LocationPreciseDenied",
        "AccessDenied.LocationTracking",
        "AccessDenied.LocationWeather",
        "AccessDenied.MicrophoneRestricted",
        "AccessDenied.PhotosAndVideos",
        "AccessDenied.PhotosRestricted",
        "AccessDenied.QrCamera",
        "AccessDenied.QrCode",
        "AccessDenied.SaveMedia",
        "AccessDenied.VideoCallCamera",
        "AccessDenied.VideoMessageCamera",
        "AccessDenied.VideoMessageMicrophone",
        "AccessDenied.VideoMicrophone",
        "AccessDenied.VoiceMicrophone",
        "AccessDenied.Wallpapers",
        "Attachment.CameraAccessText",
        "Attachment.LimitedMediaAccessText",
        "Contacts.AccessDeniedError",
        "Contacts.AccessDeniedHelpLandscape",
        "Contacts.AccessDeniedHelpPortrait",
        "Contacts.LimitedAccess.Text",
        "Contacts.PermissionsText",
        "InfoPlist.NSContactsUsageDescription",
        "InfoPlist.NSLocationAlwaysAndWhenInUseUsageDescription",
        "InfoPlist.NSLocationAlwaysUsageDescription",
        "InfoPlist.NSLocationWhenInUseUsageDescription",
        "Map.HomeAndWorkInfo",
        "Media.LimitedAccessText",
        "Notifications.PermissionsSuppressWarningText",
        "Permissions.CellularDataText.v0",
        "Story.Camera.AccessPlaceholderTitle",
        // Passcode lock.
        "DialogList.PasscodeLockHelp",
        "EnterPasscode.EnterPasscode",
        "EnterPasscode.EnterTitle",
        "EnterPasscode.TouchId",
        "Intents.ErrorLockedText",
        "Passcode.AppLockedAlert",
        "PasscodeSettings.EncryptDataHelp",
        "PasscodeSettings.LockTelegram",
        // Local storage.
        "Cache.Indexing",
        "ClearCache.ClearCache",
        "ClearCache.StorageCache",
        "ClearCache.StorageServiceFiles",
        "StorageManagement.DescriptionAppUsage",
        "StorageManagement.DescriptionChatUsage",
        // Updates and content this version cannot show.
        "Conversation.UnsupportedMedia",
        "Conversation.UnsupportedMedia.Text",
        "Conversation.UnsupportedMediaPlaceholder",
        "Gift.Transfer.UpdateRequired.Text",
        "Login.ErrorAppOutdated",
        "Passport.UpdateRequiredError",
        "Story.UnsupportedAction",
        "Story.UnsupportedText",
        "Update.AppVersion",
        "Update.Title",
        "Update.UpdateApp",
        // Extensions, widgets and the watch.
        "Application.Name",
        "ChatImportActivity.OpenApp",
        "Share.AuthDescription",
        "Share.AuthTitle",
        "Watch.AppName",
        "Watch.AuthRequired",
        "Watch.Location.Access",
        "Watch.Microphone.Access",
        "Widget.AuthRequired",
        "Widget.GalleryTitle",
        // Sharing files into the app and its in-app browser.
        "Conversation.FileHowToText",
        "ShareFileTip.Text",
        "WebBrowser.ClearCookies.Info",
        "WebBrowser.OpenLinksInfo",
        "WebBrowser.Telegram",
        // Other.
        "AuthSessions.AddDeviceIntro.Text1",
        "AuthSessions.AddDeviceIntro.Text2",
        "Login.PhoneGenericEmailSubject",
        "PowerSavingScreen.OptionAutoplayEffectsText",
        // END identity keys
    ]

    /// Only `NanogramBranding.rewrites` apply to these: they link Telegram's desktop download,
    /// which now leads to Nanogram's releases, but their other "Telegram"s name Telegram's own
    /// products (Telegram Web).
    static let rewriteOnlyKeys: [String] = [
        // BEGIN rewrite-only keys
        "AuthSessions.AddDevice.ScanInstallInfo",
        "AuthSessions.HeaderInfo",
        // END rewrite-only keys
    ]
}
