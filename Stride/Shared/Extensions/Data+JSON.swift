import Foundation

extension Data {
    /// Decodes this data as a JSON-encoded value of the given type.
    /// Returns `nil` on failure; callers supply their own fallback.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: self)
    }

    /// JSON-encodes a value into `Data`. Returns `nil` on failure.
    static func encoded<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }
}
