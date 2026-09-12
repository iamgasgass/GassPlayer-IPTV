import Foundation

enum FlexibleArrayDecoder {
    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T] {
        if let array = try? JSONDecoder().decode([T].self, from: data) {
            return array
        }
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            if let dict = jsonObject as? [String: Any], dict.isEmpty { return [] }
            if let bool = jsonObject as? Bool, bool == false { return [] }
        }
        return []
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: K) -> Int? {
        if let intValue = try? decode(Int.self, forKey: key) { return intValue }
        if let stringValue = try? decode(String.self, forKey: key), let parsed = Int(stringValue) { return parsed }
        if let doubleValue = try? decode(Double.self, forKey: key) { return Int(doubleValue) }
        return nil
    }

    func decodeFlexibleString(forKey key: K) -> String? {
        if let stringValue = try? decode(String.self, forKey: key) { return stringValue }
        if let intValue = try? decode(Int.self, forKey: key) { return String(intValue) }
        if let doubleValue = try? decode(Double.self, forKey: key) { return String(doubleValue) }
        return nil
    }
}
