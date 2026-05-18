import Foundation

extension KeyedDecodingContainer {
    func decodeRawJSON(forKey key: Key) throws -> Data {
        let decoder = try superDecoder(forKey: key)
        let container = try decoder.singleValueContainer()
        let jsonObject = try container.decode(RawJSON.self)
        return try JSONSerialization.data(withJSONObject: jsonObject.value, options: [])
    }
}

struct RawJSON: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let arrayValue = try? container.decode([RawJSON].self) {
            value = arrayValue.map { $0.value }
        } else if let dictionaryValue = try? container.decode([String: RawJSON].self) {
            value = dictionaryValue.mapValues { $0.value }
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode raw JSON value"
            )
        }
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}
