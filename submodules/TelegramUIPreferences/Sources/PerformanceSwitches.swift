import Foundation

/// The performance switches in Debug Settings, set and logged as one group, so a device A/B is one tap and every log line
/// says which variant it measured. Renderers (stickers, emoji) and calls are not in the group: they change memory and
/// quality, not just timing.
public extension ExperimentalUISettings {
    /// Sets every switch to our variant (`optimized`) or to Telegram's behaviour. Two switches are Telegram's behaviour
    /// when on: the display-link rate and the accessibility timing.
    func withPerformanceSwitches(optimized: Bool) -> ExperimentalUISettings {
        var settings = self
        settings.emojiPanelDefersHeavyWork = optimized
        settings.chatOpenDeferSetup = optimized
        settings.chatOpenPrewarmWallpaperPattern = optimized
        settings.displayLinkUpstreamRate = !optimized
        settings.listAccessibilityImmediate = !optimized
        settings.chatListLazyRareSubnodes = optimized
        settings.chatListRowReuse = optimized
        settings.chatListAsyncMediaWhileScrolling = optimized
        settings.backSwipePreparePreviousScreen = optimized
        settings.chatScrollExperiments = optimized ? (ExperimentalUISettings.chatScrollPrepareLayoutAhead | ExperimentalUISettings.chatScrollReuseRowViews) : 0
        return settings
    }

    /// `set=ours|telegram|mixed` and every switch, for the ` ab=` part of measurement log lines.
    var performanceSwitchesSummary: String {
        let set: String
        if self == self.withPerformanceSwitches(optimized: true) {
            set = "ours"
        } else if self == self.withPerformanceSwitches(optimized: false) {
            set = "telegram"
        } else {
            set = "mixed"
        }
        let on: (Bool) -> String = { $0 ? "on" : "off" }
        return "set=\(set) emojiDefer=\(on(self.emojiPanelDefersHeavyWork)) openDefer=\(on(self.chatOpenDeferSetup)) wallPrewarm=\(on(self.chatOpenPrewarmWallpaperPattern)) upstreamRate=\(on(self.displayLinkUpstreamRate)) a11yNow=\(on(self.listAccessibilityImmediate)) lazyRows=\(on(self.chatListLazyRareSubnodes)) rowReuse=\(on(self.chatListRowReuse)) asyncMedia=\(on(self.chatListAsyncMediaWhileScrolling)) backPrep=\(on(self.backSwipePreparePreviousScreen)) chatRows=\(self.chatScrollExperiments) ipadCap=\(on(self.tabletDisplayLinkFrameRateCap))"
    }
}
