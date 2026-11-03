import XCTest
@testable import ChatTranslationDisplay

final class ChatTranslationDisplayTests: XCTestCase {
    private let ukrainian = ChatTranslationDetectedState(fromLang: "uk", toLang: nil, isEnabled: true)

    private func resolve(_ state: ChatTranslationDetectedState?, isHidden: Bool = false, isOffered: Bool = true, canTranslateMessages: Bool = true) -> ChatTranslationResolution {
        return ChatTranslationDisplayPolicy.resolve(state: state, isHidden: isHidden, isOffered: isOffered, canTranslateMessages: canTranslateMessages, baseLanguageCode: "en")
    }

    // A channel with autotranslation, a viewer who once tapped the bar's X (or "Hide" in its menu,
    // on any device: `translationHidden` is synced from the server). The bar is gone, so the
    // messages must be the originals. They used to stay translated with nothing on screen to
    // show the original.
    func testHiddenBarMeansMessagesAreNotTranslated() {
        let resolution = self.resolve(self.ukrainian, isHidden: true)
        XCTAssertNil(resolution.bar)
        XCTAssertNil(resolution.messageLanguages)
    }

    // No language detected in the recent messages: the bar has nothing to say, so nothing is translated.
    func testUndetectedLanguageMeansNoBarAndNoTranslation() {
        let resolution = self.resolve(ChatTranslationDetectedState(fromLang: "", toLang: "en", isEnabled: true))
        XCTAssertNil(resolution.bar)
        XCTAssertNil(resolution.messageLanguages)
    }

    func testTranslatedChatShowsTheBarWithShowOriginal() {
        let resolution = self.resolve(self.ukrainian)
        XCTAssertEqual(resolution.bar, ChatTranslationDisplay(isEnabled: true, fromLang: "uk", toLang: "en"))
        XCTAssertEqual(resolution.messageLanguages?.fromLang, "uk")
        XCTAssertEqual(resolution.messageLanguages?.toLang, "en")
    }

    func testChosenTargetLanguageWins() {
        let resolution = self.resolve(ChatTranslationDetectedState(fromLang: "uk", toLang: "de", isEnabled: true))
        XCTAssertEqual(resolution.bar?.toLang, "de")
        XCTAssertEqual(resolution.messageLanguages?.toLang, "de")
    }

    func testShowOriginalSticks() {
        let resolution = self.resolve(ChatTranslationDetectedState(fromLang: "uk", toLang: "en", isEnabled: false))
        XCTAssertEqual(resolution.bar?.isEnabled, false)
        XCTAssertNil(resolution.messageLanguages)
    }

    func testChatInTheAppLanguageOffersNothingUntilEnabled() {
        XCTAssertNil(self.resolve(ChatTranslationDetectedState(fromLang: "en", toLang: nil, isEnabled: false)).bar)
        // Enabled (translated into another language) keeps its bar so it can be turned off.
        let on = self.resolve(ChatTranslationDetectedState(fromLang: "en", toLang: "uk", isEnabled: true))
        XCTAssertEqual(on.bar?.isEnabled, true)
        XCTAssertEqual(on.messageLanguages?.toLang, "uk")
    }

    func testNotOfferedMeansNoBarAndNoTranslation() {
        let resolution = self.resolve(self.ukrainian, isOffered: false)
        XCTAssertNil(resolution.bar)
        XCTAssertNil(resolution.messageLanguages)
    }

    // Premium lapsed, no channel autotranslation: the bar may still be shown, the messages are not translated.
    func testBarWithoutTranslationRightsTranslatesNothing() {
        let resolution = self.resolve(self.ukrainian, canTranslateMessages: false)
        XCTAssertNotNil(resolution.bar)
        XCTAssertNil(resolution.messageLanguages)
    }

    // The invariant the tester's report broke: messages are never shown translated unless the
    // bar is on screen offering "Show Original".
    func testMessagesAreTranslatedOnlyWhileTheBarOffersShowOriginal() {
        var states: [ChatTranslationDetectedState?] = [nil]
        for fromLang in ["", "en", "uk"] {
            for toLang in [nil, "en", "uk"] as [String?] {
                for isEnabled in [false, true] {
                    states.append(ChatTranslationDetectedState(fromLang: fromLang, toLang: toLang, isEnabled: isEnabled))
                }
            }
        }
        for state in states {
            for isHidden in [false, true] {
                for isOffered in [false, true] {
                    for canTranslateMessages in [false, true] {
                        let resolution = self.resolve(state, isHidden: isHidden, isOffered: isOffered, canTranslateMessages: canTranslateMessages)
                        if resolution.messageLanguages != nil {
                            XCTAssertEqual(resolution.bar?.isEnabled, true, "\(String(describing: state)) hidden=\(isHidden) offered=\(isOffered) can=\(canTranslateMessages)")
                        }
                    }
                }
            }
        }
    }
    // MARK: - Message views outside the list (the media viewer's caption)

    private func messageLanguages(_ state: ChatTranslationDetectedState?, isHidden: Bool = false, isPremium: Bool = true, hasAutoTranslate: Bool = false) -> (fromLang: String, toLang: String)? {
        return ChatTranslationDisplayPolicy.messageLanguages(state: state, isHidden: isHidden, isPremium: isPremium, hasAutoTranslate: hasAutoTranslate, baseLanguageCode: "en")
    }

    // The reviewer's case: an autotranslated channel with the bar hidden. The chat shows the
    // originals, so the media viewer must too; it used to show the caption translated, with no
    // "Show Original" anywhere.
    func testHiddenBarMeansOriginalCaptionsInTheMediaViewer() {
        XCTAssertNil(self.messageLanguages(self.ukrainian, isHidden: true, isPremium: false, hasAutoTranslate: true))
        XCTAssertNil(self.messageLanguages(self.ukrainian, isHidden: true, isPremium: true))
    }

    func testUndetectedLanguageMeansOriginalCaptions() {
        XCTAssertNil(self.messageLanguages(ChatTranslationDetectedState(fromLang: "", toLang: "en", isEnabled: true)))
    }

    // A stored "translate" choice without Premium or channel autotranslation translates nothing.
    func testNoTranslationRightsMeansOriginalCaptions() {
        XCTAssertNil(self.messageLanguages(self.ukrainian, isPremium: false, hasAutoTranslate: false))
    }

    func testShowOriginalMeansOriginalCaptions() {
        XCTAssertNil(self.messageLanguages(ChatTranslationDetectedState(fromLang: "uk", toLang: "en", isEnabled: false)))
    }

    func testTranslatedChatTranslatesCaptions() {
        let premium = self.messageLanguages(self.ukrainian)
        XCTAssertEqual(premium?.fromLang, "uk")
        XCTAssertEqual(premium?.toLang, "en")
        let autoTranslated = self.messageLanguages(ChatTranslationDetectedState(fromLang: "uk", toLang: "de", isEnabled: true), isPremium: false, hasAutoTranslate: true)
        XCTAssertEqual(autoTranslated?.toLang, "de")
    }

    // Same answer as the list, for every input: the list and the media viewer never disagree.
    func testMessageLanguagesMatchTheList() {
        var states: [ChatTranslationDetectedState?] = [nil]
        for fromLang in ["", "en", "uk"] {
            for toLang in [nil, "en", "uk"] as [String?] {
                for isEnabled in [false, true] {
                    states.append(ChatTranslationDetectedState(fromLang: fromLang, toLang: toLang, isEnabled: isEnabled))
                }
            }
        }
        for state in states {
            for isHidden in [false, true] {
                for isPremium in [false, true] {
                    for hasAutoTranslate in [false, true] {
                        let canTranslateMessages = isPremium || hasAutoTranslate
                        let list = self.resolve(state, isHidden: isHidden, isOffered: canTranslateMessages, canTranslateMessages: canTranslateMessages).messageLanguages
                        let other = self.messageLanguages(state, isHidden: isHidden, isPremium: isPremium, hasAutoTranslate: hasAutoTranslate)
                        XCTAssertEqual(list?.fromLang, other?.fromLang)
                        XCTAssertEqual(list?.toLang, other?.toLang)
                    }
                }
            }
        }
    }
}
