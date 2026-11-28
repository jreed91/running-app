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

    /// JSON-encodes a value into `Data`, falling back to `current` (the data already
    /// stored) when encoding fails. `JSONEncoder` rejects non-conforming floats
    /// (`NaN`/`±inf`) by default, so a single bad coordinate or split would otherwise
    /// make the setter assign `nil` and silently **wipe** previously stored data.
    /// Preserving `current` keeps the last good blob intact on a transient failure.
    static func encoded<T: Encodable>(_ value: T, keeping current: Data?) -> Data? {
        (try? JSONEncoder().encode(value)) ?? current
    }
}
