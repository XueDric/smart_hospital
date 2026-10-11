package qingzhou

import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * jsonx.cj 边界情况测试。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 覆盖 5 个边界情况（12 个 @Test）：
 *   1. 空对象            —— 空 JsonObject / "{}" 解析体上取任何字段都失败软化
 *   2. 类型不符          —— 数值当字符串读、对象当数组读，均不得抛异常
 *   3. 嵌套              —— 多层对象访问、缺失/类型不符的中间层
 *   4. 特殊字符          —— 引号/反斜杠/换行/制表符/中文的转义与保真
 *   5. 超大数字          —— Int64.MaxValue 往返、超范围字面量在解析层暴露、
 *                          浮动序列化的量级边界（含一处 stdx 缺陷，见该测试注释）
 *
 * 约定：与 unit_tests.cj 一致，@Expect / @Assert 通过 std.unittest.testmacro 提供。
 * 断言只走 jsonx.cj 的公开 API（jsonGetXxx / JsonBuilder / jsonMissing）+
 * JsonValue.fromStr 解析，与 unit_tests.cj 同一层次，无需构造 Context。
 */

/* ============ 1. 空对象 ============ */

@Test
func jsonx_edge_empty_object_all_accessors_none(): Unit {
    // 空对象（零字段）上取任何字段都必须返回 None，而不是抛异常。
    let empty = JsonObject()
    @Expect(empty.size(), 0)

    match (jsonGetStr(empty, "name")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetInt64(empty, "n")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetFloat64(empty, "f")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetBool(empty, "b")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetObject(empty, "o")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetArray(empty, "a")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }

    // 空键名同样不应命中。
    match (jsonGetStr(empty, "")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }

    // 空对象序列化后必须是 "{}"，且 jsonMissing 报告第一个键。
    @Expect(JsonBuilder().build(), "{}")
    match (jsonMissing(empty, ["x"])) {
        case Some(k) => @Expect(k, "x")
        case None => @Assert(false)
    }
}

@Test
func jsonx_edge_empty_object_parsed_from_braces(): Unit {
    // 从字面量 "{}" 解析出来的对象，行为应与手工构造的空对象一致。
    let parsed = JsonValue.fromStr("{}")
    @Expect(parsed.asObject().size(), 0)
    match (jsonGetStr(parsed.asObject(), "anything")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

/* ============ 2. 类型不符 ============ */

@Test
func jsonx_edge_type_mismatch_fails_soft(): Unit {
    // 每个字段只以「一种」类型存在，用其余类型的访问器读它，
    // 都必须软化到 None（stdx 的 asXxx() 会抛 JsonException，
    // jsonx 的 try/catch 负责消化它）。
    let obj = JsonValue.fromStr(
        "{\"s\":\"text\",\"n\":42,\"f\":1.5,\"b\":true,\"o\":{\"k\":1},\"a\":[1,2,3]}"
    ).asObject()

    // 字符串字段：只接受 String。
    match (jsonGetStr(obj, "s")) {
        case Some(v) => @Expect(v, "text")
        case None => @Assert(false)
    }
    match (jsonGetInt64(obj, "s")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetBool(obj, "s")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }

    // 整数字段：读 Int64 可以，读 String 必须失败。
    match (jsonGetInt64(obj, "n")) {
        case Some(v) => @Expect(v, 42)
        case None => @Assert(false)
    }
    match (jsonGetStr(obj, "n")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }

    // 布尔字段：反向验证，避免「恒为 None」的假通过。
    match (jsonGetBool(obj, "b")) {
        case Some(v) => @Expect(v, true)
        case None => @Assert(false)
    }
    match (jsonGetInt64(obj, "b")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }

    // 对象字段当数组读、数组字段当对象读：跨容器类型也不能抛。
    match (jsonGetArray(obj, "o")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetObject(obj, "a")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

/* ============ 3. 嵌套 ============ */

@Test
func jsonx_edge_nested_object_roundtrip(): Unit {
    // builder 构造两层嵌套，序列化后重新解析，逐层读取。
    let inner = JsonObject()
    inner.put("name", JsonString("alice"))
    inner.put("age", JsonInt(30))

    let serialized = JsonBuilder()
        .put("id", "u-1")
        .putObject("profile", inner)
        .build()

    let root = JsonValue.fromStr(serialized).asObject()
    @Expect(jsonGetStr(root, "id").getOrThrow(), "u-1")

    match (jsonGetObject(root, "profile")) {
        case Some(p) =>
            @Expect(jsonGetStr(p, "name").getOrThrow(), "alice")
            @Expect(jsonGetInt64(p, "age").getOrThrow(), 30)
            // 嵌套层里的缺失字段同样是 None。
            match (jsonGetStr(p, "nope")) {
                case Some(_) => @Assert(false)
                case None => @Assert(true)
            }
            // 嵌套层里的类型不符同样是 None。
            match (jsonGetStr(p, "age")) {
                case Some(_) => @Assert(false)
                case None => @Assert(true)
            }
        case None => @Assert(false)
    }
}

@Test
func jsonx_edge_nested_array_of_objects(): Unit {
    // 三层结构：对象 -> 数组 -> 对象，验证 asArray()/size/索引读取。
    let parsed = JsonValue.fromStr(
        "{\"items\":[{\"id\":1},{\"id\":2},{\"id\":3}]}"
    ).asObject()

    match (jsonGetArray(parsed, "items")) {
        case Some(arr) =>
            @Expect(arr.size(), 3)
            let first = arr[0].asObject()
            @Expect(jsonGetInt64(first, "id").getOrThrow(), 1)
            let last = arr[2].asObject()
            @Expect(jsonGetInt64(last, "id").getOrThrow(), 3)
            // 数组里元素当字符串读必须软化。
            match (jsonGetStr(first, "id")) {
                case Some(_) => @Assert(false)
                case None => @Assert(true)
            }
        case None => @Assert(false)
    }

    // 中间层缺失时，外层命中、内层软化。
    let nestedMissing = JsonValue.fromStr("{\"outer\":{}}").asObject()
    match (jsonGetObject(nestedMissing, "outer")) {
        case Some(o) =>
            match (jsonGetObject(o, "inner")) {
                case Some(_) => @Assert(false)
                case None => @Assert(true)
            }
        case None => @Assert(false)
    }
}

/* ============ 4. 特殊字符 ============ */

@Test
func jsonx_edge_special_chars_escaped_and_preserved(): Unit {
    // 双引号 / 反斜杠 / 换行 / 制表符 / 中文混在一个值里：
    // 序列化必须转义控制字符与引号反斜杠，解析回来必须逐字保真。
    let original = "he said \"hi\"\\ 换行:\n 制表:\t 结束"
    let built = JsonBuilder().put("k", original).build()

    // 转义产物检查。
    @Expect(built.contains("he said"), true)
    @Expect(built.contains("\\\""), true)   // 引号被转义
    @Expect(built.contains("\\\\"), true)   // 反斜杠被转义
    @Expect(built.contains("\\n"), true)    // 换行被转义为 \n（两字符）
    @Expect(built.contains("\\t"), true)    // 制表符被转义为 \t（两字符）
    @Expect(built.contains("换行"), true)   // 中文原样保留
    // 未转义的裸换行不得出现在 JSON 文本里。
    @Expect(built.contains("\n"), false)

    // 往返保真。
    let back = JsonValue.fromStr(built).asObject()
    match (jsonGetStr(back, "k")) {
        case Some(v) => @Expect(v, original)
        case None => @Assert(false)
    }
}

@Test
func jsonx_edge_special_chars_in_nested_values(): Unit {
    // 特殊字符出现在嵌套对象与数组键值里时，同样要转义 + 保真。
    let inner = JsonObject()
    inner.put("path", JsonString("C:\\tmp\\\"q\""))
    let serialized = JsonBuilder().putObject("meta", inner).build()

    @Expect(serialized.contains("C:\\\\tmp"), true)

    let back = JsonValue.fromStr(serialized).asObject()
    match (jsonGetObject(back, "meta")) {
        case Some(m) =>
            @Expect(jsonGetStr(m, "path").getOrThrow(), "C:\\tmp\\\"q\"")
        case None => @Assert(false)
    }

    // 数组元素里的特殊字符。
    let arr = JsonValue.fromStr("[\"a\\nb\",\"c\\td\"]").asArray()
    @Expect(arr.size(), 2)
    @Expect(arr[0].asString().getValue(), "a\nb")
    @Expect(arr[1].asString().getValue(), "c\td")
}

/* ============ 5. 超大数字 ============ */

@Test
func jsonx_edge_huge_int64_roundtrip(): Unit {
    // Int64.MaxValue 必须原样序列化并往返，不得溢出或变浮点。
    let big = JsonBuilder()
        .putInt("max", 9223372036854775807)
        .putInt("min", -9223372036854775808)
        .build()

    @Expect(big.contains("9223372036854775807"), true)
    @Expect(big.contains("-9223372036854775808"), true)

    let back = JsonValue.fromStr(big).asObject()
    @Expect(jsonGetInt64(back, "max").getOrThrow(), 9223372036854775807)
    @Expect(jsonGetInt64(back, "min").getOrThrow(), -9223372036854775808)

    // 超大整数不应当成字符串读出。
    match (jsonGetStr(back, "max")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func jsonx_edge_malformed_huge_number_throws_at_parse(): Unit {
    // 超出 Int64 范围的「纯整数」字面量（99999999999999999999999999）
    // 会让 stdx 解析器直接抛 JsonException（错误信息 Parse Error:
    // Unexpected character: '}'），即 JsonValue.fromStr 本身就会抛。
    //
    // 因此这层边界不在 jsonGetXxx（它只是 try/catch 的 asInt() 包装），
    // 而在更上游的解析入口。jsonx.cj 的 body 入口用 try/catch 兜住它：
    //   Context.bodyJson()  -> try { Some(JsonValue.fromStr(raw)) } catch { None }
    //   bodyStr/bodyInt64   -> bodyJson() 为 None 时直接返回 None
    // 即调用方拿到的是 None，不是异常。这里直接验证该异常确实存在，
    // 从而说明上游守护不是多余的（body 入口需要真的 Context，见 unit_tests.cj）。
    let malformed = "{\"huge\":99999999999999999999999999}"

    var threw = false
    try {
        JsonValue.fromStr(malformed)
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)

    // 同样的边界从"合法"一侧逼近：Int64.MaxValue 可解析，
    // Int64.MaxValue + 1 立刻转为解析失败（不是静默钳制）。
    @Expect(jsonGetInt64(JsonValue.fromStr("{\"f\":9223372036854775807}").asObject(), "f").getOrThrow(), 9223372036854775807)

    var overflowThrew = false
    try {
        JsonValue.fromStr("{\"f\":9223372036854775808}")
    } catch (e: Exception) {
        overflowThrew = true
    }
    @Expect(overflowThrew, true)
}

@Test
func jsonx_edge_beyond_int64_scientific_notation(): Unit {
    // 科学计数法表示的超大数字走 Float64 通道，可以正常解析；
    // 读 Int64 必须失败（值远超 Int64 范围），读 Float64 量级正确。
    let parsed = JsonValue.fromStr("{\"huge\":1e26}").asObject()

    match (jsonGetInt64(parsed, "huge")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    match (jsonGetFloat64(parsed, "huge")) {
        case Some(f) => @Expect(f > 1.0e25, true)
        case None => @Assert(false)
    }
}

@Test
func jsonx_edge_large_float_precision(): Unit {
    // 普通小数的精度往返：0.1 / 1.5 / 3.141593 在构建->解析后原值返回。
    for (v in [0.1, 1.5, 3.141593]) {
        let s = JsonBuilder().putFloat("d", v).build()
        let back = JsonValue.fromStr(s).asObject()
        @Expect(jsonGetFloat64(back, "d").getOrThrow(), v)
    }

    // 同一数值再走一遍「序列化 -> 解析 -> 安全访问器」全链路，确认稳定。
    let built = JsonBuilder().putFloat("d", 1.5).build()
    let viaBody = JsonValue.fromStr(built).asObject()
    @Expect(jsonGetFloat64(viaBody, "d").getOrThrow(), 1.5)
}

@Test
func jsonx_edge_huge_float_serialization_is_known_lossy(): Unit {
    // 已知的 stdx 缺陷（需框架侧或 stdx 侧修）
    //
    // JsonObject/JsonBuilder 的 JsonFloat 序列化不做指数化：它把浮点写成
    // 「无小数点、无指数的全精度数字文本」。于是量级 >= 1e19 的浮点会序列化成
    // 超过 Int64 范围的整数字面量，读回时解析器按整数处理并直接报错：
    //
    //   putFloat(1.0e19)  ->  {"f":10000000000000000000}   -> 解析 PARSE_FAIL
    //   putFloat(9.0e18)  ->  {"f":9000000000000000000}    -> 解析 OK（<= Int64.Max）
    //
    // 本测试把边界钉死：能往返的必须往返，不能往返的必须抛（而不是静默丢精度）。
    // 若将来 stdx/jsonx 改为指数化输出，本测试的第二个断言会失败，提示更新此处。

    // 边界内侧：<= 9e18 可往返。
    let ok = JsonBuilder().putFloat("f", 9.0e18).build()
    let okBack = JsonValue.fromStr(ok).asObject()
    @Expect(jsonGetFloat64(okBack, "f").getOrThrow(), 9.0e18)

    // 边界外侧：1e19 序列化后已超 Int64，解析必然失败。
    let lossy = JsonBuilder().putFloat("f", 1.0e19).build()
    var threw = false
    try {
        JsonValue.fromStr(lossy)
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)

    // 解析失败是"响亮"的（抛异常 -> 上游 bodyJson 折成 None），
    // 不是静默截断成错误数值。这一点是失败安全的：不会读到 9223372036854775807
    // 这类被钳制的假值。
    @Expect(jsonGetInt64(JsonValue.fromStr("{\"f\":1}").asObject(), "f").getOrThrow(), 1)
}
