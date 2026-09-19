import Foundation

extension UserDefaults {
    /// Reads a value stored as JSON, or `nil` if there is none that this
    /// version can read.
    ///
    /// Both stores keep their whole state as one blob under a single key. An
    /// unreadable value is treated as an absent one: state this app owns
    /// entirely and can rebuild is not worth failing a launch over.
    func codable<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setCodable<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}
