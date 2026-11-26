import Foundation
import Postbox
        
public class DerivedDataMessageAttribute: MessageAttribute {
    private struct EntryData: PostboxCoding {
        var data: CodableEntry
        
        init(data: CodableEntry) {
            self.data = data
        }
        
        init(decoder: PostboxDecoder) {
            self.data = CodableEntry(data: decoder.decodeDataForKey("d") ?? Data())
        }
        
        func encode(_ encoder: PostboxEncoder) {
            encoder.encodeData(self.data.data, forKey: "d")
        }
    }
    
    public let data: [String: CodableEntry]

    public init(data: [String: CodableEntry]) {
        self.data = data
    }
    
    required public init(decoder: PostboxDecoder) {
        let data = decoder.decodeObjectDictionaryForKey("d", keyDecoder: { key in
            return key.decodeStringForKey("k", orElse: "")
        }, valueDecoder: { value in
            return EntryData(data: CodableEntry(data: value.decodeDataForKey("d") ?? Data()))
        })
        self.data = data.mapValues(\.data)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectDictionary(self.data.mapValues(EntryData.init(data:)), forKey: "d", keyEncoder: { k, e in
            e.encodeString(k, forKey: "k")
        })
    }
}

/// A message's attributes with its derived data replaced by what `update` makes of it, or nil when that is the data
/// the message already holds, so the write can be skipped. A message without the attribute holds empty data, and empty
/// data removes the attribute, so the two count as the same. (A playing gallery video stores its position every few
/// seconds, often the same value; each write rewrites the whole message and updates every view that shows it.)
func attributesReplacingDerivedData(_ attributes: [MessageAttribute], update: ([String: CodableEntry]) -> [String: CodableEntry]) -> [MessageAttribute]? {
    var current: [String: CodableEntry] = [:]
    if let attribute = attributes.first(where: { $0 is DerivedDataMessageAttribute }) as? DerivedDataMessageAttribute {
        current = attribute.data
    }
    var attributes = attributes.filter { !($0 is DerivedDataMessageAttribute) }
    let updated = update(current)
    if updated == current {
        return nil
    }
    if !updated.isEmpty {
        attributes.append(DerivedDataMessageAttribute(data: updated))
    }
    return attributes
}
