package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 运维台（admin 构建）专用
 * —— jsonw.cj 里那 6 个小工具的自包含替身。
 *
 * 背景
 *   server/src/store.cj / store_persistence.cj / store_queries.cj（社团数据模型、原子落盘、查询辅助）要被编进 admin 构建，
 *   好让运维台直接读社团库。它用到这 6 个工具：
 *     jPutInt / jPutStr / jPutBool / reqIntOr / reqStrOr / reqBoolOr
 *   而它们定义在 server/src/jsonw.cj —— 那一张会连带把 ApiError / V 校验器 /
 *   响应壳 / 我们服务端的错误码表一起拖进 admin 构建，运维台不需要那些。
 *   所以这里给一份**语义完全一致**的独立实现：jsonw.cj 改口径时这里要跟着看一眼。
 *
 * 为什么不会和服务端构建撞车
 *   - 服务端构建取的是 `server/src` 下的 `*.cj`（**不递归**），本文件在 `server/src/ops/` 下，
 *     因此 jsonw.cj 的同名函数永远不会和这一份出现在同一次编译里（轻舟"同包同名"是本项目
 *     记录过的坑，见 docs/API-NOTES.md 坑 2）。
 *   - 运维台构建（build.ps1 -Target admin）只取 Store 三文件 / timex.cj / strx.cj /
 *     fw_rbac_store.cj + 本目录，不取 jsonw.cj。
 */

import stdx.encoding.json.*

/* 与 jsonw.cj:24 一致。 */
public func jPutStr(o: JsonObject, k: String, v: String): JsonObject {
    o.put(k, JsonString(v))
    return o
}

/* 与 jsonw.cj:29 一致。 */
public func jPutInt(o: JsonObject, k: String, v: Int64): JsonObject {
    o.put(k, JsonInt(v))
    return o
}

/* 与 jsonw.cj:34 一致。 */
public func jPutBool(o: JsonObject, k: String, v: Bool): JsonObject {
    o.put(k, JsonBool(v))
    return o
}

/* 与 jsonw.cj:119 一致：缺失/类型不符 → 默认值。 */
public func reqStrOr(o: JsonObject, k: String, d: String): String {
    return jsonGetStr(o, k) ?? d
}

/* 与 jsonw.cj:123 一致。 */
public func reqIntOr(o: JsonObject, k: String, d: Int64): Int64 {
    return jsonGetInt64(o, k) ?? d
}

/* 与 jsonw.cj:127 一致。 */
public func reqBoolOr(o: JsonObject, k: String, d: Bool): Bool {
    return jsonGetBool(o, k) ?? d
}
