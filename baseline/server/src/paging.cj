package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 分页与查询参数（api-design §1.7）。
 *
 * 约定：page 从 **1** 开始（不是 0）；size 默认 50、最大 200，超出按 200 处理。
 * 参数非法一律退回默认值——列表接口不该因为一个坏 query 就报错。
 */

import std.collection.*
import std.convert.*
import stdx.encoding.json.*

public class Page {
    public var page: Int64 = 1
    public var size: Int64 = 50

    public init() {}
}

/* 解析 page / size。非数字、超长、越界一律回退默认值。 */
public func pageOf(ctx: Context): Page {
    let p = Page()
    let rawPage = ctx.queryParamOr("page", "")
    let rawSize = ctx.queryParamOr("size", "")
    var pg: Int64 = 1
    var sz: Int64 = 50
    if (rawPage.size > 0 && rawPage.size <= 9 && isDigits(rawPage)) {
        pg = Int64.parse(rawPage)
    }
    if (rawSize.size > 0 && rawSize.size <= 9 && isDigits(rawSize)) {
        sz = Int64.parse(rawSize)
    }
    if (pg < 1) {
        pg = 1
    }
    if (sz < 1) {
        sz = 50
    }
    if (sz > 200) {
        sz = 200
    }
    p.page = pg
    p.size = sz
    return p
}

/* 取整型 query 参数，缺失/非法返回 d。 */
public func queryIntOr(ctx: Context, name: String, d: Int64): Int64 {
    let raw = ctx.queryParamOr(name, "")
    if (raw.size == 0 || raw.size > 12 || !isDigits(raw)) {
        return d
    }
    return Int64.parse(raw)
}

/* 纯函数版的切片：便于单测（不依赖 Context）。 */
public func pagedSlice(all: ArrayList<JsonObject>, page: Int64, size: Int64): JsonObject {
    var pg = page
    var sz = size
    if (pg < 1) {
        pg = 1
    }
    if (sz < 1) {
        sz = 50
    }
    if (sz > 200) {
        sz = 200
    }
    let total = all.size
    let start = (pg - 1) * sz
    let arr = JsonArray()
    var i = start
    while (i < total && i < start + sz) {
        arr.add(all[i])
        i += 1
    }
    let o = JsonObject()
    o.put("items", arr)
    jPutInt(o, "total", total)
    jPutInt(o, "page", pg)
    jPutInt(o, "size", sz)
    return o
}

/* 把内存里已经筛好的全量结果按 page/size 切片，并带上 total。 */
public func pagedJson(ctx: Context, all: ArrayList<JsonObject>): JsonObject {
    let pg = pageOf(ctx)
    return pagedSlice(all, pg.page, pg.size)
}

/*
 * 路径参数里的整型 id。
 * 非数字（例如客户端把 /members/abc 当 id 用）直接按"资源不存在"处理，
 * 不要漏成 500。
 */
public func pathIdOr(ctx: Context, notFoundCode: String): Int64 {
    let raw = ctx.paramOr("id", "")
    if (raw.size == 0 || raw.size > 18 || !isDigits(raw)) {
        throw apiErr(notFoundCode)
    }
    return Int64.parse(raw)
}
