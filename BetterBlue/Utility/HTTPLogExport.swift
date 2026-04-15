//
//  HTTPLogExport.swift
//  BetterBlue
//
//  Shared Encodable wrapper around `HTTPLog` that inlines request/response
//  bodies as actual JSON values instead of re-escaped strings. Used by both
//  the per-entry share sheet (`HTTPLogDetailView`) and the whole-debug
//  export (`SettingsView`), so both produce readable logs.
//

import BetterBlueKit
import Foundation

/// Wrapper for `HTTPLog` whose `Encodable` conformance embeds
/// request/response bodies as nested JSON objects when they parse as JSON.
/// Falls back to the raw string when the body is not JSON (HTML error pages,
/// plain text, binary, etc.).
struct HTTPLogExport: Encodable {
    let log: HTTPLog

    enum CodingKeys: String, CodingKey {
        case timestamp, accountId, requestType, method, url
        case requestHeaders, requestBody
        case responseStatus, responseHeaders, responseBody
        case error, apiError, duration, stackTrace, vin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(log.timestamp, forKey: .timestamp)
        try container.encode(log.accountId, forKey: .accountId)
        try container.encode(log.requestType, forKey: .requestType)
        try container.encode(log.method, forKey: .method)
        try container.encode(log.url, forKey: .url)
        try container.encode(log.requestHeaders, forKey: .requestHeaders)
        try container.encodeIfPresent(log.responseStatus, forKey: .responseStatus)
        try container.encode(log.responseHeaders, forKey: .responseHeaders)
        try container.encodeIfPresent(log.error, forKey: .error)
        try container.encodeIfPresent(log.apiError, forKey: .apiError)
        try container.encode(log.duration, forKey: .duration)
        try container.encodeIfPresent(log.stackTrace, forKey: .stackTrace)
        try container.encodeIfPresent(log.vin, forKey: .vin)

        if let body = log.requestBody {
            try Self.encodeJSONBody(body, forKey: .requestBody, in: &container)
        }
        if let body = log.responseBody {
            try Self.encodeJSONBody(body, forKey: .responseBody, in: &container)
        }
    }

    private static func encodeJSONBody(
        _ body: String,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let data = body.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            if let dict = jsonObject as? [String: Any] {
                try container.encode(AnyJSONValue(dict), forKey: key)
                return
            }
            if let array = jsonObject as? [Any] {
                try container.encode(AnyJSONValue(array), forKey: key)
                return
            }
        }
        // Not a JSON object/array — keep as-is.
        try container.encode(body, forKey: key)
    }
}

/// Type-erased `Encodable` for arbitrary JSON values (dicts, arrays,
/// strings, numbers, bools, null). Recurses through `[String: Any]` and
/// `[Any]` so nested structures render as real JSON in the output.
struct AnyJSONValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyJSONValue.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyJSONValue.init))
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}
