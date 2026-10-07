package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * JSON 写入/读取的统一出口（API 响应 + 请求取参 + 落盘）。
 *
 * 为什么要有这一层：
 *   1. 手写 JSON 字符串拼接一定会漏转义（成员姓名、任务描述里出现引号就炸）
 *   2. 统一响应包装（{ok,data} / {ok,error}）只应有一处实现，
 *      否则某个接口忘了包 ok 字段，客户端就要写特例
 */

import std.collection.*
import stdx.encoding.json.*

/* ===================== 构建 JSON ===================== */

public func jObj(): JsonObject {
    return JsonObject()
}

public func jPutStr(o: JsonObject, k: String, v: String): JsonObject {
    o.put(k, JsonString(v))
    return o
}

public func jPutInt(o: JsonObject, k: String, v: Int64): JsonObject {
    o.put(k, JsonInt(v))
    return o
}

public func jPutBool(o: JsonObject, k: String, v: Bool): JsonObject {
    o.put(k, JsonBool(v))
    return o
}

public func jPutObj(o: JsonObject, k: String, v: JsonObject): JsonObject {
    o.put(k, v)
    return o
}

public func jPutArr(o: JsonObject, k: String, v: JsonArray): JsonObject {
    o.put(k, v)
    return o
}

public func jPutNull(o: JsonObject, k: String): JsonObject {
    o.put(k, JsonNull())
    return o
}

/* epoch 秒；0 表示"无此时间"，输出 null（api-design §1.8：可选时间用 null，不用空字符串）。 */
public func jPutTime(o: JsonObject, k: String, epoch: Int64): JsonObject {
    if (epoch > 0) {
        o.put(k, JsonString(isoLocal(epoch)))
    } else {
        o.put(k, JsonNull())
    }
    return o
}

/* 单字段错误，用于 VALIDATION_FAILED 的 fields。 */
public func oneField(k: String, msg: String): JsonObject {
    let f = JsonObject()
    f.put(k, JsonString(msg))
    return f
}

/* ===================== 响应包装 ===================== */

public func sendRoot(ctx: Context, status_: Int64, data: JsonObject): Unit {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("data", data)
    ctx.status(status_).json(root.toString())
}

public func sendOk(ctx: Context, data: JsonObject): Unit {
    sendRoot(ctx, 200, data)
}

public func sendCreated(ctx: Context, data: JsonObject): Unit {
    sendRoot(ctx, 201, data)
}

/* 失败响应。HTTP 状态码由错误码表决定，body 里同时给 code 与 message。 */
public func sendError(ctx: Context, e: ApiError): Unit {
    let err = JsonObject()
    err.put("code", JsonString(e.code))
    err.put("message", JsonString(e.message))
    match (e.fields) {
        case Some(f) => err.put("fields", f)
        case None => err.put("fields", JsonObject())
    }
    let root = JsonObject()
    root.put("ok", JsonBool(false))
    root.put("error", err)
    ctx.status(e.status_).json(root.toString())
}

/* ===================== 请求取参 ===================== */

/* 请求体必须是 JSON 对象，否则 VALIDATION_FAILED。 */
public func reqObj(ctx: Context): JsonObject {
    match (ctx.bodyJson()) {
        case Some(v) =>
            try {
                return v.asObject()
            } catch (e: Exception) {
                throw apiErrMsg("VALIDATION_FAILED", "请求体必须是 JSON 对象")
            }
        case None =>
            throw apiErrMsg("VALIDATION_FAILED", "缺少请求体或 JSON 解析失败")
    }
}

/* 可选请求字段：缺失或显式 null 表示未提供；键存在但类型错误必须拒绝。 */
public func reqOptionalStr(o: JsonObject, k: String): ?String {
    match (o.get(k)) {
        case None => return None
        case Some(v) =>
            match (v) {
                case _: JsonNull => return None
                case _: JsonString => return Some(jsonGetStr(o, k) ?? "")
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是字符串"))
            }
    }
}

public func reqOptionalInt(o: JsonObject, k: String): ?Int64 {
    match (o.get(k)) {
        case None => return None
        case Some(v) =>
            match (v) {
                case _: JsonNull => return None
                case _: JsonInt => return Some(jsonGetInt64(o, k) ?? 0)
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是整数"))
            }
    }
}

public func reqStrOr(o: JsonObject, k: String, d: String): String {
    match (o.get(k)) {
        case None => return d
        case Some(v) =>
            match (v) {
                case _: JsonNull => return d
                case _: JsonString => return jsonGetStr(o, k) ?? d
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是字符串"))
            }
    }
}

public func reqIntOr(o: JsonObject, k: String, d: Int64): Int64 {
    match (o.get(k)) {
        case None => return d
        case Some(v) =>
            match (v) {
                case _: JsonNull => return d
                case _: JsonInt => return jsonGetInt64(o, k) ?? d
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是整数"))
            }
    }
}

public func reqBoolOr(o: JsonObject, k: String, d: Bool): Bool {
    match (o.get(k)) {
        case None => return d
        case Some(v) =>
            match (v) {
                case _: JsonNull => return d
                case _: JsonBool => return jsonGetBool(o, k) ?? d
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是布尔值"))
            }
    }
}

/*
 * 取时间字段：缺失 / null / 空串 → 0（表示"无此时间"）；
 * 有值但格式非法 → VALIDATION_FAILED（绝不静默当成没填）。
 */
public func reqTime(o: JsonObject, k: String): Int64 {
    match (o.get(k)) {
        case None => return 0
        case Some(v) =>
            match (v) {
                case _: JsonNull => return 0
                case _: JsonString =>
                    let s = jsonGetStr(o, k) ?? ""
                    if (isBlank(s)) {
                        return 0
                    }
                    match (parseIso(s)) {
                        case Some(t) => return t
                        case None => throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField(k, "时间格式不正确，应为 2026-09-20T18:00:00+08:00"))
                    }
                case _ =>
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField(k, "必须是 ISO 8601 时间字符串或 null"))
            }
    }
}

/*
 * 字段校验收集器：一次把所有字段问题收集齐再抛，
 * 让表单能一次性逐字段提示，而不是让用户改一个提交一次。
 */
public class V {
    public let fields = JsonObject()
    public var bad: Int64 = 0

    public init() {}

    /* 必填：空则记错。返回原值便于链式使用。 */
    public func need(key: String, value: String, msg: String): String {
        if (isBlank(value)) {
            fields.put(key, JsonString(msg))
            bad += 1
        }
        return value
    }

    /* 条件校验：不满足则记错。 */
    public func check(key: String, ok: Bool, msg: String): Unit {
        if (!ok) {
            fields.put(key, JsonString(msg))
            bad += 1
        }
    }

    public func done(): Unit {
        if (bad > 0) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败", fields)
        }
    }
}
