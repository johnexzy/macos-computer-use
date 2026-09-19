import Foundation
import CoreGraphics
import AppKit

func printJson(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func parseJSONObject(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return nil
    }
    return dictionary
}

func parseStringArray(_ raw: String) -> [String]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let array = object as? [String] else {
        return nil
    }
    return array
}

func normalizedAXText(_ value: String) -> String {
    return value
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .unicodeScalars
        .filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        .map(String.init)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

func normalizedText(_ text: String) -> String {
    return text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
    )
}

func isWordCodeUnit(_ value: unichar) -> Bool {
    guard let scalar = UnicodeScalar(value) else { return false }
    return CharacterSet.alphanumerics.contains(scalar) || value == 95
}
