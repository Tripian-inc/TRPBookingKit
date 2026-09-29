import Foundation

/// Decodes `json` as `type` with a plain `JSONDecoder`, matching what every model in the package uses.
func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}
