import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext

final class NanogramFeaturesControllerArguments {
    let updateFeatures: (@escaping (NanogramFeaturesSettings) -> NanogramFeaturesSettings) -> Void
    let updateExperimental: (@escaping (ExperimentalUISettings) -> ExperimentalUISettings) -> Void
    let openGroupNoiseMode: () -> Void

    init(updateFeatures: @escaping (@escaping (NanogramFeaturesSettings) -> NanogramFeaturesSettings) -> Void, updateExperimental: @escaping (@escaping (ExperimentalUISettings) -> ExperimentalUISettings) -> Void, openGroupNoiseMode: @escaping () -> Void) {
        self.updateFeatures = updateFeatures
        self.updateExperimental = updateExperimental
        self.openGroupNoiseMode = openGroupNoiseMode
    }
}

private enum NanogramFeaturesSection: Int32 {
    case search
    case links
    case onDevice
    case calls
    case widgets
    case voice
}

private func nanogramGroupNoiseModeTitle(_ mode: Int32) -> String {
    switch mode {
    case 1:
        return "WebRTC only"
    case 2:
        return "RNNoise only"
    default:
        return "Both"
    }
}

enum NanogramFeaturesEntry: ItemListNodeEntry {
    case searchHeader
    case searchOperators(Bool)
    case searchFooter

    case linksHeader
    case stripTracking(Bool)
    case confirmTelegramLinks(Bool)
    case linksFooter

    case onDeviceHeader
    case onDeviceTranscription(Bool)
    case onDeviceTranslation(Bool)
    case onDeviceFooter

    case callsHeader
    case callsSystemNoiseSuppression(Bool)
    case callsAdvancedDucking(Bool)
    case callsGroupNoiseMode(Int32)
    case callsThermalVideoLadder(Bool)
    case callsFooter

    case widgetsHeader
    case glanceables(Bool)
    case widgetsFooter

    case voiceHeader
    case voiceEnhancement(Bool)
    case voiceFooter

    var section: ItemListSectionId {
        switch self {
        case .searchHeader, .searchOperators, .searchFooter:
            return NanogramFeaturesSection.search.rawValue
        case .linksHeader, .stripTracking, .confirmTelegramLinks, .linksFooter:
            return NanogramFeaturesSection.links.rawValue
        case .onDeviceHeader, .onDeviceTranscription, .onDeviceTranslation, .onDeviceFooter:
            return NanogramFeaturesSection.onDevice.rawValue
        case .callsHeader, .callsSystemNoiseSuppression, .callsAdvancedDucking, .callsGroupNoiseMode, .callsThermalVideoLadder, .callsFooter:
            return NanogramFeaturesSection.calls.rawValue
        case .widgetsHeader, .glanceables, .widgetsFooter:
            return NanogramFeaturesSection.widgets.rawValue
        case .voiceHeader, .voiceEnhancement, .voiceFooter:
            return NanogramFeaturesSection.voice.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .searchHeader:
            return 0
        case .searchOperators:
            return 1
        case .searchFooter:
            return 2
        case .linksHeader:
            return 10
        case .stripTracking:
            return 11
        case .confirmTelegramLinks:
            return 12
        case .linksFooter:
            return 13
        case .onDeviceHeader:
            return 15
        case .onDeviceTranscription:
            return 16
        case .onDeviceTranslation:
            return 17
        case .onDeviceFooter:
            return 18
        case .callsHeader:
            return 20
        case .callsSystemNoiseSuppression:
            return 21
        case .callsAdvancedDucking:
            return 22
        case .callsGroupNoiseMode:
            return 23
        case .callsThermalVideoLadder:
            return 24
        case .callsFooter:
            return 25
        case .widgetsHeader:
            return 30
        case .glanceables:
            return 31
        case .widgetsFooter:
            return 32
        case .voiceHeader:
            return 40
        case .voiceEnhancement:
            return 41
        case .voiceFooter:
            return 42
        }
    }

    static func <(lhs: NanogramFeaturesEntry, rhs: NanogramFeaturesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? NanogramFeaturesControllerArguments else {
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "", sectionId: self.section)
        }
        switch self {
        case .searchHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "SEARCH", sectionId: self.section)
        case let .searchOperators(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Search Operators", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFeatures { settings in
                    var settings = settings
                    settings.searchOperators = value
                    return settings
                }
            })
        case .searchFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Narrow a search inside a chat. Operators: from:@name, before:2026-11-01, after:2026-11-01, date:today, type:photo (also video, file, link, voice, music, gif, round, poll, pinned). Anything else stays ordinary search text."), sectionId: self.section)
        case .linksHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LINKS", sectionId: self.section)
        case let .stripTracking(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Remove Tracking from Links", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFeatures { settings in
                    var settings = settings
                    settings.stripTrackingParameters = value
                    return settings
                }
            })
        case let .confirmTelegramLinks(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Confirm Telegram Links", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFeatures { settings in
                    var settings = settings
                    settings.confirmTelegramLinks = value
                    return settings
                }
            })
        case .linksFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Removes tracking parameters such as utm_source and fbclid when you open or copy a link. The text of messages you send is never changed. Confirm Telegram Links asks before a t.me or tg:// link opens."), sectionId: self.section)
        case .onDeviceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ON-DEVICE", sectionId: self.section)
        case let .onDeviceTranscription(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "On-Device Voice Transcription", text: "Voice messages are turned into text on this phone, and the audio is never sent to Telegram for it. The first use downloads a language model of about 50-100 MB for your language; until it is there, or if your language is not supported, no text appears. When off, Telegram's own transcription is used.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateExperimental { settings in
                    var settings = settings
                    settings.localTranscription = value
                    return settings
                }
            })
        case let .onDeviceTranslation(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "On-Device Translation", text: "Messages, polls and voice transcriptions in a translated chat are translated on this phone with Apple's Translation, and their text is not sent to Telegram for it. The first use of a language pair asks to download a language model of about 50-100 MB. If you cancel the download, the text stays untranslated. When off, Telegram's own translation is used.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFeatures { settings in
                    var settings = settings
                    settings.onDeviceTranslation = value
                    return settings
                }
            })
        case .onDeviceFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Both are off by default. With a switch on, nothing falls back to Telegram's servers for that job. Rich-text messages are not translated while the translation switch is on, and the Translate action in the message menu can still use Telegram."), sectionId: self.section)
        case .callsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "CALLS", sectionId: self.section)
        case let .callsSystemNoiseSuppression(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "System Noise Suppression", text: "Lets the system voice-processing unit do all noise suppression and drops the extra software one. Applies to the next call.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateExperimental { settings in
                    var settings = settings
                    settings.callsSystemNoiseSuppression = value
                    return settings
                }
            })
        case let .callsAdvancedDucking(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Advanced Ducking", text: "Other audio is lowered only while someone speaks, and only a little. Applies to the next call.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateExperimental { settings in
                    var settings = settings
                    settings.callsAdvancedDucking = value
                    return settings
                }
            })
        case let .callsGroupNoiseMode(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Group Noise Suppression", label: nanogramGroupNoiseModeTitle(value), sectionId: self.section, style: .blocks, action: {
                arguments.openGroupNoiseMode()
            })
        case let .callsThermalVideoLadder(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Thermal Video Limits", text: "When the phone is hot, the outgoing camera video gets smaller and slower. Applies at once.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateExperimental { settings in
                    var settings = settings
                    settings.callsThermalVideoLadder = value
                    return settings
                }
            })
        case .callsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Group Noise Suppression chooses which noise suppressors run in group calls (default: RNNoise only). Applies to the next group call."), sectionId: self.section)
        case .widgetsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "WIDGETS AND SHORTCUTS", sectionId: self.section)
        case let .glanceables(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Widgets, Live Activities, Shortcuts", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateExperimental { settings in
                    var settings = settings
                    settings.nanogramGlanceables = value
                    return settings
                }
            })
        case .widgetsFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Turns on the chats widget (small and Lock Screen), the Saved Messages control, Live Activities for live location and calls without CallKit, and the Shortcuts actions. Chat names show only while the app is unlocked and, on the Lock Screen, only if names are allowed in notification settings."), sectionId: self.section)
        case .voiceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "VOICE MESSAGES", sectionId: self.section)
        case let .voiceEnhancement(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Enhance voice messages", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFeatures { settings in
                    var settings = settings
                    settings.voiceEnhancement = value
                    return settings
                }
            })
        case .voiceFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Cleans up the voice in voice messages while they play, using Opus speech enhancement on this phone. Uses a little more battery during playback. Applies from the next message you play. Off by default."), sectionId: self.section)
        }
    }
}

func nanogramFeaturesControllerEntries(features: NanogramFeaturesSettings, experimental: ExperimentalUISettings) -> [NanogramFeaturesEntry] {
    var entries: [NanogramFeaturesEntry] = []
    entries.append(.searchHeader)
    entries.append(.searchOperators(features.searchOperators))
    entries.append(.searchFooter)

    entries.append(.linksHeader)
    entries.append(.stripTracking(features.stripTrackingParameters))
    entries.append(.confirmTelegramLinks(features.confirmTelegramLinks))
    entries.append(.linksFooter)

    entries.append(.onDeviceHeader)
    entries.append(.onDeviceTranscription(experimental.localTranscription))
    entries.append(.onDeviceTranslation(features.onDeviceTranslation))
    entries.append(.onDeviceFooter)

    entries.append(.callsHeader)
    entries.append(.callsSystemNoiseSuppression(experimental.callsSystemNoiseSuppression))
    entries.append(.callsAdvancedDucking(experimental.callsAdvancedDucking))
    entries.append(.callsGroupNoiseMode(experimental.callsGroupNoiseMode))
    entries.append(.callsThermalVideoLadder(experimental.callsThermalVideoLadder))
    entries.append(.callsFooter)

    entries.append(.widgetsHeader)
    entries.append(.glanceables(experimental.nanogramGlanceables))
    entries.append(.widgetsFooter)

    entries.append(.voiceHeader)
    entries.append(.voiceEnhancement(features.voiceEnhancement))
    entries.append(.voiceFooter)
    return entries
}

public func nanogramFeaturesController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController) -> Void)?

    let accountManager = context.sharedContext.accountManager
    let arguments = NanogramFeaturesControllerArguments(
        updateFeatures: { f in
            let _ = updateNanogramFeaturesSettingsInteractively(accountManager: accountManager, f).start()
        },
        updateExperimental: { f in
            let _ = updateExperimentalUISettingsInteractively(accountManager: accountManager, f).start()
        },
        openGroupNoiseMode: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            var items: [ActionSheetItem] = [
                ActionSheetTextItem(title: "Which noise suppressors run in group calls. Default: RNNoise only. Applies to the next group call.")
            ]
            for mode in [Int32(0), Int32(1), Int32(2)] {
                items.append(ActionSheetButtonItem(title: nanogramGroupNoiseModeTitle(mode), color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    let _ = updateExperimentalUISettingsInteractively(accountManager: accountManager, { settings in
                        var settings = settings
                        settings.callsGroupNoiseMode = mode
                        return settings
                    }).start()
                }))
            }
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(actionSheet)
        }
    )

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.nanogramFeaturesSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
    )
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let features = sharedData.entries[ApplicationSpecificSharedDataKeys.nanogramFeaturesSettings]?.get(NanogramFeaturesSettings.self) ?? NanogramFeaturesSettings.defaultSettings
        let experimental = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Nanogram Features"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: nanogramFeaturesControllerEntries(features: features, experimental: experimental), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
