import Foundation
import MCP

/// MCP Tool 参数提取辅助
///
/// 简化从 `CallTool.Parameters.arguments` 中提取各类型参数的操作。
/// SDK 的 `Value` 类型已提供 `stringValue`, `intValue`, `arrayValue` 等属性。
enum ParamHelpers {

    /// 提取 required string 参数
    static func requireString(_ params: CallTool.Parameters, key: String) throws -> String {
        guard let value = params.arguments?[key]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        return value
    }

    /// 提取 optional string 参数
    static func optionalString(_ params: CallTool.Parameters, key: String) -> String? {
        params.arguments?[key]?.stringValue
    }

    /// 提取 required integer 参数
    static func requireInt(_ params: CallTool.Parameters, key: String) throws -> Int {
        if let val = params.arguments?[key] {
            // strict: false 允许 int/double/string 都转为 Int
            if let intVal = Int(val, strict: false) {
                return intVal
            }
        }
        throw MCPError.invalidParams("Missing required parameter: \(key)")
    }

    /// 提取 optional integer 参数
    static func optionalInt(_ params: CallTool.Parameters, key: String) -> Int? {
        guard let val = params.arguments?[key] else { return nil }
        return Int(val, strict: false)
    }

    /// 提取 string array 参数
    static func optionalStringArray(_ params: CallTool.Parameters, key: String) -> [String]? {
        guard let arr = params.arguments?[key]?.arrayValue else { return nil }
        return arr.compactMap { $0.stringValue }
    }

    /// 提取 required string array 参数
    static func requireStringArray(_ params: CallTool.Parameters, key: String) throws -> [String] {
        guard let arr = params.arguments?[key]?.arrayValue else {
            throw MCPError.invalidParams("Missing required parameter: \(key)")
        }
        return arr.compactMap { $0.stringValue }
    }

    /// 将 Codable 对象编码为 JSON 字符串
    static func toJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
