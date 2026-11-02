import Foundation
import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// The models carry explicit snake_case `CodingKeys` (tools/watch/add_coding_keys.py) instead of
/// relying on `.convertFromSnakeCase`. For every generated struct this builds a sample value with
/// every field set, and checks that the plain coders TDLibApi now uses produce and accept exactly
/// the JSON the snake-case strategies did.
final class TDModelCodingKeysTests: XCTestCase {

    func test_everyModel_plainCodersMatchSnakeCaseStrategies() throws {
        let snakeEncoder = JSONEncoder()
        snakeEncoder.keyEncodingStrategy = .convertToSnakeCase
        let plainEncoder = JSONEncoder()
        let plainDecoder = JSONDecoder()

        var checked = 0
        for type in tdModelStructs {
            try check(type, snakeEncoder: snakeEncoder, plainEncoder: plainEncoder, plainDecoder: plainDecoder)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 500)
    }

    func test_tdlibApi_usesPlainCoders() {
        let api = TDLibApi()
        guard case .useDefaultKeys = api.decoder.keyDecodingStrategy else {
            return XCTFail("TDLibApi must decode with the models' own keys")
        }
        guard case .useDefaultKeys = api.encoder.keyEncodingStrategy else {
            return XCTFail("TDLibApi must encode with the models' own keys")
        }
    }

    /// A real TDLib message decodes the same through the plain decoder as it used to.
    func test_fixtureMessage_decodesWithPlainDecoder() throws {
        let data = Data(CoreFixtures.messageJSON(id: 10, text: "hello").utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(message.id, 10)
        XCTAssertEqual(message.chatId, CoreFixtures.chatId)
        XCTAssertEqual(message.senderId, .messageSenderUser(MessageSenderUser(userId: 2)))
        guard case .messageText(let text) = message.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.text.text, "hello")
    }

    private func check<T: Codable & Equatable>(
        _ type: T.Type,
        snakeEncoder: JSONEncoder,
        plainEncoder: JSONEncoder,
        plainDecoder: JSONDecoder
    ) throws {
        let name = String(describing: T.self)
        let sample = try T(from: SampleDecoder(typeName: name, depth: 0))
        let snakeJSON = try snakeEncoder.encode(sample)
        let plainJSON = try plainEncoder.encode(sample)
        let snakeObject = try JSONSerialization.jsonObject(with: snakeJSON, options: .fragmentsAllowed)
        let plainObject = try JSONSerialization.jsonObject(with: plainJSON, options: .fragmentsAllowed)
        XCTAssertEqual(snakeObject as? NSObject, plainObject as? NSObject, "\(name): encoded keys differ")
        XCTAssertEqual(try plainDecoder.decode(T.self, from: snakeJSON), sample, "\(name): snake_case JSON does not round-trip")
    }
}

/// Builds a value of any generated model with every field present: optionals set, arrays with one
/// element, enums as their first `@type`, down to a fixed depth (so recursive types end).
private struct SampleDecoder: Decoder {
    let typeName: String
    let depth: Int
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static let maxDepth = 6

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(Keyed<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        Unkeyed(decoder: self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        Single(decoder: self)
    }

    func child<T: Decodable>(_ type: T.Type) throws -> T {
        if let value = Self.primitive(type) { return value }
        return try T(from: SampleDecoder(typeName: String(describing: T.self), depth: depth + 1))
    }

    var hasRoom: Bool { depth < Self.maxDepth }

    static func primitive<T>(_ type: T.Type) -> T? {
        switch type {
        case is String.Type: return "42" as? T
        case is Bool.Type: return true as? T
        case is Int.Type: return 42 as? T
        case is Int32.Type: return Int32(42) as? T
        case is Int64.Type: return Int64(42) as? T
        case is Double.Type: return 1.5 as? T
        case is Float.Type: return Float(1.5) as? T
        case is UInt8.Type: return UInt8(42) as? T
        default: return nil
        }
    }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: SampleDecoder
        var codingPath: [CodingKey] { [] }
        var allKeys: [Key] { [] }

        func contains(_ key: Key) -> Bool { key.stringValue == "@type" || decoder.hasRoom }
        func decodeNil(forKey key: Key) throws -> Bool { false }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            if key.stringValue == "@type", T.self == String.self {
                guard let kind = tdModelEnumSampleType[decoder.typeName] else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [key], debugDescription: "no sample @type for \(decoder.typeName)"))
                }
                return kind as! T
            }
            return try decoder.child(type)
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            KeyedDecodingContainer(Keyed<NestedKey>(decoder: decoder))
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            Unkeyed(decoder: decoder)
        }

        func superDecoder() throws -> Decoder { decoder }
        func superDecoder(forKey key: Key) throws -> Decoder { decoder }
    }

    struct Unkeyed: UnkeyedDecodingContainer {
        let decoder: SampleDecoder
        var codingPath: [CodingKey] { [] }
        var count: Int? { decoder.hasRoom ? 1 : 0 }
        var currentIndex = 0
        var isAtEnd: Bool { currentIndex >= (count ?? 0) }

        init(decoder: SampleDecoder) { self.decoder = decoder }

        mutating func decodeNil() throws -> Bool { false }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            currentIndex += 1
            return try decoder.child(type)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            currentIndex += 1
            return KeyedDecodingContainer(Keyed<NestedKey>(decoder: decoder))
        }

        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            currentIndex += 1
            return Unkeyed(decoder: decoder)
        }

        mutating func superDecoder() throws -> Decoder { decoder }
    }

    struct Single: SingleValueDecodingContainer {
        let decoder: SampleDecoder
        var codingPath: [CodingKey] { [] }

        func decodeNil() -> Bool { false }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try decoder.child(type)
        }
    }
}
