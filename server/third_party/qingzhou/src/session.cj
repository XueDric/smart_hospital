package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 服务端 session。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 基于签名 cookie 的会话管理：
 *   - cookie 里存的是「签名后的 sessionId」（signValue/verifySigned），
 *     客户端无法伪造（除非拿到 secret）
 *   - session 数据存服务端内存（SessionStore），cookie 只带 id
 *
 * 用法：
 *   let store = SessionStore()
 *   app.use(session(store, "my-secret"))
 *   // handler 里：
 *   let sid = ctx.getStateOr("sid", "")
 *   store.set(sid, "user", "alice")
 *   store.get(sid, "user")  // -> ?String
 */

/* 内存 session 存储。生产可换成 Redis/DB 后端。 */
public class SessionStore {
    private let data: HashMap<String, HashMap<String, String>> = HashMap<String, HashMap<String, String>>()

    public init() {}

    /* 创建新 session，返回 sessionId（32 字节随机 hex）。 */
    public func create(): String {
        let id = randomHex(32)
        data[id] = HashMap<String, String>()
        return id
    }

    public func exists(id: String): Bool {
        match (data.get(id)) {
            case Some(_) => true
            case None => false
        }
    }

    public func get(id: String, key: String): ?String {
        match (data.get(id)) {
            case Some(m) => m.get(key)
            case None => None
        }
    }

    public func set(id: String, key: String, value: String): Unit {
        match (data.get(id)) {
            case Some(m) => m[key] = value
            case None => ()
        }
    }

    public func destroy(id: String): Unit {
        data.remove(id)
    }
}

/*
 * session 中间件：从 sid cookie 恢复 sessionId 到 ctx.state。
 * 签名无效 / 无 cookie 时不报错，只是 state 里没有 sid（匿名）。
 * 新建会话由 handler 调 store.create() + 写 cookie 完成。
 */
public func session(store: SessionStore, secret: String): Middleware {
    return { ctx: Context, next: () -> Unit =>
        match (ctx.cookies.get("sid")) {
            case Some(signed) =>
                match (verifySigned(signed, secret)) {
                    case Some(sid) =>
                        if (store.exists(sid)) {
                            ctx.setState("sid", sid)
                        }
                    case None => ()
                }
            case None => ()
        }
        next()
    }
}
