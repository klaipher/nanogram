import Foundation
import TelegramCore
import SwiftSignalKit

/// Settings > Nanogram features: switches for Nanogram's own tweaks. Defaults are listed in the spec
/// docs/specs/search-operators.md (search operators on, link hygiene off).
public struct NanogramFeaturesSettings: Codable, Equatable {
    public var searchOperators: Bool
    public var stripTrackingParameters: Bool
    public var confirmTelegramLinks: Bool
    public var onDeviceTranslation: Bool

    public static var defaultSettings: NanogramFeaturesSettings {
        return NanogramFeaturesSettings(searchOperators: true, stripTrackingParameters: false, confirmTelegramLinks: false, onDeviceTranslation: false)
    }

    public init(searchOperators: Bool, stripTrackingParameters: Bool, confirmTelegramLinks: Bool, onDeviceTranslation: Bool = false) {
        self.searchOperators = searchOperators
        self.stripTrackingParameters = stripTrackingParameters
        self.confirmTelegramLinks = confirmTelegramLinks
        self.onDeviceTranslation = onDeviceTranslation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let defaults = NanogramFeaturesSettings.defaultSettings
        self.searchOperators = try container.decodeIfPresent(Bool.self, forKey: "searchOperators") ?? defaults.searchOperators
        self.stripTrackingParameters = try container.decodeIfPresent(Bool.self, forKey: "stripTrackingParameters") ?? defaults.stripTrackingParameters
        self.confirmTelegramLinks = try container.decodeIfPresent(Bool.self, forKey: "confirmTelegramLinks") ?? defaults.confirmTelegramLinks
        self.onDeviceTranslation = try container.decodeIfPresent(Bool.self, forKey: "onDeviceTranslation") ?? defaults.onDeviceTranslation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.searchOperators, forKey: "searchOperators")
        try container.encode(self.stripTrackingParameters, forKey: "stripTrackingParameters")
        try container.encode(self.confirmTelegramLinks, forKey: "confirmTelegramLinks")
        try container.encode(self.onDeviceTranslation, forKey: "onDeviceTranslation")
    }

    /// The value the app last read, for places that cannot wait for a signal (opening and copying a link).
    /// SharedAccountContext keeps it up to date.
    public static let current = Atomic<NanogramFeaturesSettings>(value: NanogramFeaturesSettings.defaultSettings)
}

public func updateNanogramFeaturesSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (NanogramFeaturesSettings) -> NanogramFeaturesSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.nanogramFeaturesSettings, { entry in
            let currentSettings: NanogramFeaturesSettings
            if let entry = entry?.get(NanogramFeaturesSettings.self) {
                currentSettings = entry
            } else {
                currentSettings = NanogramFeaturesSettings.defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
