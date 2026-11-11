/// What decides whether a chat row's content is the same as in the previous history update (spec R20, "history
/// update re-lays out every row"). `allUpdated` re-submits every loaded entry on each update; a row whose inputs did not
/// change keeps its `stableVersion` so the list's equality check passes and the row is not laid out again on main.
public struct ChatRowStableVersionInputs<Entry: Equatable, AssociatedData: Equatable> {
    public let entry: Entry
    /// The presentation data the entry was built with, by identity.
    public let presentationData: ObjectIdentifier?
    public let associatedData: AssociatedData
    public let rowPrepEpoch: UInt64

    public init(entry: Entry, presentationData: ObjectIdentifier?, associatedData: AssociatedData, rowPrepEpoch: UInt64) {
        self.entry = entry
        self.presentationData = presentationData
        self.associatedData = associatedData
        self.rowPrepEpoch = rowPrepEpoch
    }
}

/// The row keeps its old `stableVersion` only when its entry is unchanged AND the presentation data (identical object),
/// the associated data and the row-prep epoch (the other state a row's layout reads) are the same. Anything else, or no
/// previous value, gives a new version, as before.
public func shouldKeepStableVersion<Entry: Equatable, AssociatedData: Equatable>(old: ChatRowStableVersionInputs<Entry, AssociatedData>?, new: ChatRowStableVersionInputs<Entry, AssociatedData>) -> Bool {
    guard let old else {
        return false
    }
    return old.presentationData == new.presentationData
        && old.rowPrepEpoch == new.rowPrepEpoch
        && old.associatedData == new.associatedData
        && old.entry == new.entry
}
