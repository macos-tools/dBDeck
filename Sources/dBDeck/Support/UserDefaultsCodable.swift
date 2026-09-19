import Foundation

extension UserDefaults {
    /// Both stores keep their state as one JSON blob under a single key. A
    /// failure to decode means the value is missing or written by a version
    /// this one cannot read, and in both cases starting empty is correct.
    func codable<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setCodable<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}
