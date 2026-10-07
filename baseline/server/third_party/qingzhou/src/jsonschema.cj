package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 声明式 JSON schema 校验。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 解决「逐个 jsonGetXxx + jsonMissing」的样板问题：把字段规格声明成
 * schema，一次校验拿到全部错误（而非遇到第一个就返回），便于
 * 「模型输出校验」与「入参校验」这类需要一次报全的场景。
 *
 * 典型用法：
 *   let schema = JsonSchema()
 *       .requireStr("title", minLen: 1)
 *       .requireIntIn("priority", 1, 5)
 *       .optional("note", FStr)
 *   let errs = schema.validate(obj)
 *   if (errs.size > 0) { ... }   // 逐个错误展示
 */

/* 字段类型。 */
public enum JsonFieldType {
    | FStr
    | FInt
    | FFloat
    | FBool
    | FObj
    | FArr
}

/* 单个字段的校验规格。 */
public class JsonFieldSpec {
    public let name: String
    public let fieldType: JsonFieldType
    public let required: Bool
    /* 字符串最小长度；<= 0 表示不校验。 */
    public let minLen: Int64
    public let minValue: Float64
    public let maxValue: Float64
    /* 是否启用数值范围校验（max > min 时启用）。 */
    public let hasRange: Bool

    public init(name: String, fieldType: JsonFieldType, required!: Bool = true,
                minLen!: Int64 = -1, minValue!: Float64 = 0.0, maxValue!: Float64 = 0.0) {
        this.name = name
        this.fieldType = fieldType
        this.required = required
        this.minLen = minLen
        this.minValue = minValue
        this.maxValue = maxValue
        this.hasRange = maxValue > minValue
    }

    public func typeName(): String {
        return match (fieldType) {
            case FStr => "string"
            case FInt => "int"
            case FFloat => "float"
            case FBool => "bool"
            case FObj => "object"
            case FArr => "array"
        }
    }
}

/* 声明式 schema：链式注册字段，一次性校验并收集全部错误。 */
public class JsonSchema {
    private let fields: ArrayList<JsonFieldSpec> = ArrayList<JsonFieldSpec>()

    public init() {}

    /* 必填字段。 */
    public func require(name: String, fieldType: JsonFieldType): JsonSchema {
        fields.add(JsonFieldSpec(name, fieldType, required: true))
        return this
    }

    /* 可选字段（缺失时跳过，存在则校验类型）。 */
    public func optional(name: String, fieldType: JsonFieldType): JsonSchema {
        fields.add(JsonFieldSpec(name, fieldType, required: false))
        return this
    }

    /* 必填字符串 + 可选最小长度。 */
    public func requireStr(name: String, minLen!: Int64 = -1): JsonSchema {
        fields.add(JsonFieldSpec(name, FStr, required: true, minLen: minLen))
        return this
    }

    /* 必填整数 + 取值范围（闭区间）。 */
    public func requireIntIn(name: String, minValue: Int64, maxValue: Int64): JsonSchema {
        fields.add(JsonFieldSpec(name, FInt, required: true,
            minValue: Float64(minValue), maxValue: Float64(maxValue)))
        return this
    }

    /* 已注册的字段数（测试/诊断用）。 */
    public func fieldCount(): Int64 {
        return fields.size
    }

    /*
     * 校验对象，返回错误说明列表；空列表表示全部通过。
     * 会收集所有错误而非遇到第一个就返回。
     */
    public func validate(obj: JsonObject): ArrayList<String> {
        let errs = ArrayList<String>()
        for (f in fields) {
            validateField(obj, f, errs)
        }
        return errs
    }

    public func isValid(obj: JsonObject): Bool {
        return validate(obj).size == 0
    }

    private func validateField(obj: JsonObject, f: JsonFieldSpec, errs: ArrayList<String>): Unit {
        let raw = obj.get(f.name)
        let present = match (raw) {
            case Some(_) => true
            case None => false
        }
        if (!present) {
            if (f.required) {
                errs.add("缺少必填字段: ${f.name}")
            }
            return ()
        }
        // 存在 → 类型校验
        if (!typeMatches(obj, f)) {
            errs.add("字段 ${f.name} 类型不符，期望 ${f.typeName()}")
            return ()
        }
        // 字符串长度
        if (f.minLen > 0) {
            match (jsonGetStr(obj, f.name)) {
                case Some(s) =>
                    if (s.size < f.minLen) {
                        errs.add("字段 ${f.name} 长度不足（最少 ${f.minLen} 字符）")
                    }
                case None => ()
            }
        }
        // 数值范围（int / float 都按 float 比较）
        if (f.hasRange) {
            match (jsonGetFloat64(obj, f.name)) {
                case Some(v) =>
                    if (v < f.minValue || v > f.maxValue) {
                        errs.add("字段 ${f.name} 超出范围 [${f.minValue}, ${f.maxValue}]")
                    }
                case None =>
                    match (jsonGetInt64(obj, f.name)) {
                        case Some(iv) =>
                            let fv = Float64(iv)
                            if (fv < f.minValue || fv > f.maxValue) {
                                errs.add("字段 ${f.name} 超出范围 [${f.minValue}, ${f.maxValue}]")
                            }
                        case None => ()
                    }
            }
        }
    }

    private func typeMatches(obj: JsonObject, f: JsonFieldSpec): Bool {
        return match (f.fieldType) {
            case FStr => hasSome(jsonGetStr(obj, f.name))
            case FInt => hasSome(jsonGetInt64(obj, f.name))
            case FFloat => hasSome(jsonGetFloat64(obj, f.name))
            case FBool => hasSome(jsonGetBool(obj, f.name))
            case FObj => hasSome(jsonGetObject(obj, f.name))
            case FArr => hasSome(jsonGetArray(obj, f.name))
        }
    }
}

/*
 * Option 是否有值。用 match 而非 `!= None`：后者在部分泛型 Option
 * （如 ?JsonObject / ?JsonArray）上会触发类型参数推断失败
 * （error: generic type should be used with type argument）。
 */
func hasSome<T>(v: ?T): Bool {
    return match (v) {
        case Some(_) => true
        case None => false
    }
}
