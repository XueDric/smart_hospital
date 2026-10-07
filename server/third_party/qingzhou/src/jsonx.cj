package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * JSON 工具层。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 两个薄弱点：
 *   1) 无安全访问器（stdx asString/asInt/asFloat 类型不符会抛异常）
 *   2) 无序列化 helper（手写 JSON 拼接 + 手动转义）
 *
 * 关键事实（stdx 1.0.5.1 encoding.json）：
 *   - 数字方法是 asInt() / asFloat()（不是 asNumber）
 *   - JsonObject.put(key, JsonValue) + toString() 可直接构建并序列化 JSON，
 *     toString() 会自动转义字符串，无需手写 escapeJson
 *   - JsonObject.get(key) 返回 ?JsonValue；asXxx() 返回子类（非 Option），
 *     类型不符抛 JsonException，故安全访问器内部用 try/catch 消化
 */

/* 安全访问器 */

public func jsonGetStr(obj: JsonObject, key: String): ?String {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asString().getValue()) } catch (e: Exception) { None }
        case None => return None
    }
}

public func jsonGetInt64(obj: JsonObject, key: String): ?Int64 {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asInt().getValue()) } catch (e: Exception) { None }
        case None => return None
    }
}

public func jsonGetFloat64(obj: JsonObject, key: String): ?Float64 {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asFloat().getValue()) } catch (e: Exception) { None }
        case None => return None
    }
}

public func jsonGetBool(obj: JsonObject, key: String): ?Bool {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asBool().getValue()) } catch (e: Exception) { None }
        case None => return None
    }
}

public func jsonGetObject(obj: JsonObject, key: String): ?JsonObject {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asObject()) } catch (e: Exception) { None }
        case None => return None
    }
}

public func jsonGetArray(obj: JsonObject, key: String): ?JsonArray {
    match (obj.get(key)) {
        case Some(v) => return try { Some(v.asArray()) } catch (e: Exception) { None }
        case None => return None
    }
}

/*
 * 返回第一个缺失的字段名；全部存在则返回 None。
 * 用于 body 字段校验（判空样板）。
 */
public func jsonMissing(obj: JsonObject, keys: Array<String>): ?String {
    for (k in keys) {
        if (!obj.containsKey(k)) {
            return Some(k)
        }
    }
    return None
}

/* JSON 构建器 */

/*
 * 流畅的 JSON 对象构建器。示例：
 *
 *   let body = JsonBuilder()
 *       .put("id", id.toString())        // 字符串自动转义
 *       .putInt("count", 3)
 *       .putBool("ok", true)
 *       .build()                          // -> {"id":"...","count":3,"ok":true}
 *
 * 比手写 "{\"id\":${id},...}" 更安全（自动转义、类型正确）。
 */
public class JsonBuilder {
    private let obj: JsonObject

    public init() {
        obj = JsonObject()
    }

    public func put(key: String, value: String): JsonBuilder {
        obj.put(key, JsonString(value))
        return this
    }

    public func putInt(key: String, value: Int64): JsonBuilder {
        obj.put(key, JsonInt(value))
        return this
    }

    public func putFloat(key: String, value: Float64): JsonBuilder {
        obj.put(key, JsonFloat(value))
        return this
    }

    public func putBool(key: String, value: Bool): JsonBuilder {
        obj.put(key, JsonBool(value))
        return this
    }

    public func putObject(key: String, value: JsonObject): JsonBuilder {
        obj.put(key, value)
        return this
    }

    public func putArray(key: String, value: JsonArray): JsonBuilder {
        obj.put(key, value)
        return this
    }

    /* 输出紧凑 JSON 字符串（自动转义）。 */
    public func build(): String {
        return obj.toString()
    }

    /* 拿到底层 JsonObject（供嵌套/进一步处理）。 */
    public func toObject(): JsonObject {
        return obj
    }
}

/* body 便捷读取 */

/*
 * 从请求 body 的 JSON 对象读字符串字段。封装了
 * bodyJson() -> asObject() -> get() 的样板 + 异常守护。
 * 返回 None 表示「无 body / 非对象 / 字段缺失 / 类型不符」。
 */
public func bodyStr(ctx: Context, key: String): ?String {
    match (ctx.bodyJson()) {
        case Some(v) =>
            return try { jsonGetStr(v.asObject(), key) } catch (e: Exception) { None }
        case None => return None
    }
}

/*
 * 从请求 body 的 JSON 对象读整数字段。语义同 bodyStr。
 */
public func bodyInt64(ctx: Context, key: String): ?Int64 {
    match (ctx.bodyJson()) {
        case Some(v) =>
            return try { jsonGetInt64(v.asObject(), key) } catch (e: Exception) { None }
        case None => return None
    }
}

/*
 * 从请求 body 读字符串字段，缺失/类型不符时返回 default_。
 * 用于必填字段的「读 + 判空」一步到位。
 */
public func bodyStrOr(ctx: Context, key: String, default_: String): String {
    match (bodyStr(ctx, key)) {
        case Some(s) => return s
        case None => return default_
    }
}

/* 容错 JSON 提取 */

/*
 * 从一段文本里提取第一个平衡的 JSON 对象或数组。
 *
 * `JsonValue.fromStr` 是严格解析器（见 docs/CAVEATS.md），
 * 而模型/第三方返回的文本常带杂质——markdown 代码围栏、前后解释性话术：
 *
 *   "好的，结果如下：\n```json\n{\"a\":1}\n```\n希望对你有帮助"
 *
 * 本函数扫描出其中第一个平衡的 JSON 片段，交给调用方再走严格解析。
 * 括号配对会跳过字符串字面量内部（含 \" 转义），避免把字符串里的
 * 花括号误当结构符号。
 *
 * 返回提取到的 JSON 文本（未做语法校验）；找不到平衡结构时返回 None。
 */
/* JSON 结构字符的字节值（JSON 结构符均为 ASCII，字节级判断与编码无关）。 */
let B_LBRACE: UInt8 = 0x7B
let B_RBRACE: UInt8 = 0x7D
let B_LBRACKET: UInt8 = 0x5B
let B_RBRACKET: UInt8 = 0x5D
let B_QUOTE: UInt8 = 0x22
let B_BACKSLASH: UInt8 = 0x5C

/*
 * 提取第一个平衡的 JSON 对象或数组（未做语法校验）。
 *
 * 实现按字节扫描而非字符串切片：String 的 [i..j] 按字节切，对多字节
 * UTF-8（中文等）会切断序列并抛 Invalid utf8 byte sequence；JSON 结构符
 * 都是 ASCII，字节级扫描既正确又与编码无关。括号配对会跳过字符串字面量
 * 内部（含 \" 转义）。找不到平衡结构返回 None。
 */
public func extractJson(text: String): ?String {
    let bytes = text.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == B_LBRACE || b == B_LBRACKET) {
            match (matchBalanced(bytes, i)) {
                case Some(end) => return Some(String.fromUtf8(bytes[i..end + 1]))
                case None => ()   // 该起点不闭合，继续找下一个起点
            }
        }
        i += 1
    }
    return None
}

/* 从 start 处的开括号起配对，返回收尾括号下标；不闭合或类型不匹配返回 None。 */
func matchBalanced(bytes: Array<UInt8>, start: Int64): ?Int64 {
    let opener = bytes[start]
    var depth: Int64 = 0
    var inStr = false
    var escaped = false
    var i = start
    while (i < bytes.size) {
        let b = bytes[i]
        if (inStr) {
            if (escaped) {
                escaped = false
            } else if (b == B_BACKSLASH) {
                escaped = true
            } else if (b == B_QUOTE) {
                inStr = false
            }
        } else if (b == B_QUOTE) {
            inStr = true
        } else if (b == B_LBRACE || b == B_LBRACKET) {
            depth += 1
        } else if (b == B_RBRACE || b == B_RBRACKET) {
            depth -= 1
            if (depth == 0) {
                let matched = (opener == B_LBRACE && b == B_RBRACE) || (opener == B_LBRACKET && b == B_RBRACKET)
                if (matched) {
                    return Some(i)
                }
                return None
            }
        }
        i += 1
    }
    return None
}

/*
 * extractJson + 严格解析一步到位：提取失败或 JSON 非法均返回 None。
 * 适合「拿到模型输出 → 立刻要 JsonObject」的场景。
 */
public func parseJsonLoose(text: String): ?JsonValue {
    match (extractJson(text)) {
        case Some(fragment) =>
            return try { JsonValue.fromStr(fragment) } catch (e: Exception) { None }
        case None =>
            return None
    }
}
