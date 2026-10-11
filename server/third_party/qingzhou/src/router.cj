package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * trie router.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
// Pattern syntax:
//   /users             static
//   /users/:id         :param  -> ctx.params["id"]
//   /users/:id?        optional param -> matches /users and /users/42
//                      (expanded to concrete paths at add() time, max 3 per pattern)
//   /files/STAR        trailing wildcard -> ctx.params["tail"] = "remaining/path"
//   /files/STARPATH    named trailing wildcard -> ctx.params["path"]
//   /v1/STAR/shop/...  mid-path STAR matches exactly one segment (anonymous);
//                      "/v1/STARver/shop/..." names it -> ctx.params["ver"]
//   (STAR above stands for the literal asterisk character; spelled out here
//    because an asterisk followed by a slash terminates Cangjie block comments)
//
// Naming & grouping:
//   router.get("/users/:id", h, name: "user_detail")
//   router.urlFor("user_detail", params: ...) -> "/users/42"
//   router.group("/api", mw: [...]).get("/users", h)  -> mounts at /api/users
 *
 * Lookup returns DispatchResult:
 *   Matched(h)              -> run handler, params injected into ctx
 *   MethodNotAllowed(allow) -> ctx already set to 405 + Allow header
 *   NotFound                -> ctx already set to 404 + JSON
 *
 * Use as a Middleware via `router.middleware()` so that it sits inside the
 * normal Koa-style chain (anything before/after runs naturally).
 *
 * Cangjie enum note: enum does not provide == by default, so we extend
 * SegmentKind with Equatable<SegmentKind> below to enable `c.kind == Static`.
 */

enum SegmentKind {
    | Static
    | Param
    | Wildcard
}

extend SegmentKind <: Equatable<SegmentKind> {
    public operator func ==(right: SegmentKind): Bool {
        var s: Bool = false
        match (this) {
            case SegmentKind.Static => s = match (right) { case SegmentKind.Static => true; case _ => false }
            case SegmentKind.Param => s = match (right) { case SegmentKind.Param => true; case _ => false }
            case SegmentKind.Wildcard => s = match (right) { case SegmentKind.Wildcard => true; case _ => false }
        }
        return s
    }
    public operator func !=(right: SegmentKind): Bool {
        var s: Bool = false
        match (this) {
            case SegmentKind.Static => s = match (right) { case SegmentKind.Static => false; case _ => true }
            case SegmentKind.Param => s = match (right) { case SegmentKind.Param => false; case _ => true }
            case SegmentKind.Wildcard => s = match (right) { case SegmentKind.Wildcard => false; case _ => true }
        }
        return s
    }
}

class TrieNode {
    var kind: SegmentKind = SegmentKind.Static
    var segment: String = ""
    var paramName: String = ""
    let children: ArrayList<TrieNode> = ArrayList<TrieNode>()
    let handlers: HashMap<String, Middleware> = HashMap<String, Middleware>()
    var anyHandler: Bool = false
}

public enum DispatchResult {
    | Matched(Middleware)
    | MethodNotAllowed(String)
    | NotFound
}

public class Router {
    private let root: TrieNode = TrieNode()
    /* 透传模式：NotFound 时调 next() 而非短路，支持多个 Router 串联
     * （例如公开路由 + 鉴权路由 + 静态兜底）。默认 false 保持向后兼容。 */
    public var passOnNotFound: Bool = false
    /* 命名路由表：name -> 原始 pattern（未做可选参数展开），供 urlFor 反查。 */
    private let namedRoutes: HashMap<String, String> = HashMap<String, String>()

    public init() {}

    /*
     * Add a (method, pattern) -> handler entry. method is normalised to upper case.
     * name! 登记命名路由（供 urlFor 反向生成 URL）；pattern 中的 `:x?` 可选参数
     * 在此处展开为多条具体路径（组合上限 3 个可选参数，防止组合爆炸）。
     */
    public func add(method: String, pattern: String, h: Middleware, name!: ?String = None): Router {
        match (name) {
            case Some(n) => namedRoutes[n] = pattern
            case None => ()
        }
        let patterns = expandOptional(pattern)
        for (p in patterns) {
            insert(method, p, h)
        }
        return this
    }

    public func get(p: String, h: Middleware, name!: ?String = None): Router { add("GET", p, h, name: name) }
    public func post(p: String, h: Middleware, name!: ?String = None): Router { add("POST", p, h, name: name) }
    public func put(p: String, h: Middleware, name!: ?String = None): Router { add("PUT", p, h, name: name) }
    public func delete(p: String, h: Middleware, name!: ?String = None): Router { add("DELETE", p, h, name: name) }
    public func patch(p: String, h: Middleware, name!: ?String = None): Router { add("PATCH", p, h, name: name) }
    public func all(p: String, h: Middleware, name!: ?String = None): Router { add("*", p, h, name: name) }

    /*
     * 反向生成 URL：按命名路由的原始 pattern，把 `:x` / `*name` 段替换为
     * params 提供的值。可选参数 `:x?` 未提供时跳过该段；必填参数缺失或
     * 名称未登记时返回 None。
     */
    public func urlFor(name: String, params!: HashMap<String, String> = HashMap<String, String>()): ?String {
        let pattern = match (namedRoutes.get(name)) {
            case Some(p) => p
            case None => return None
        }
        let segs = splitPath(pattern)
        let out = ArrayList<String>()
        for (seg in segs) {
            if (seg.size > 0 && seg[0] == 0x3A) { // ":"
                var key = seg[1..]
                var optional = false
                if (key.size > 0 && key[key.size - 1] == 0x3F) {
                    key = key[0..(key.size - 1)]
                    optional = true
                }
                match (params.get(key)) {
                    case Some(v) => out.add(v)
                    case None =>
                        if (!optional) {
                            return None
                        }
                }
            } else if (seg.size > 0 && seg[0] == 0x2A) { // "*"
                var key = seg[1..]
                if (key.size == 0) {
                    key = "tail"
                }
                match (params.get(key)) {
                    case Some(v) => out.add(v)
                    case None => return None
                }
            } else {
                out.add(seg)
            }
        }
        return Some("/" + String.join(out.toArray(), delimiter: "/"))
    }

    /*
     * 分组路由：返回带前缀的 RouteGroup，其上的注册自动挂到 prefix 下。
     * mw! 为组级中间件（包裹组内所有 handler，洋葱语义）；嵌套 group 的
     * 中间件链继承父组。路由树仍是单棵（共享 root），分组只是注册便捷层。
     */
    public func group(prefix: String, mw!: Array<Middleware> = Array<Middleware>()): RouteGroup {
        let list = ArrayList<Middleware>()
        for (m in mw) {
            list.add(m)
        }
        return RouteGroup(this, prefix, list)
    }

    /*
     * Resolve method+path against the trie. Side-effects the ctx on
     * non-match: 404 JSON for NotFound, 405 + Allow for MethodNotAllowed.
     * (This lets unit tests assert directly against ctx without going
     * through middleware().)
     */
    public func lookup(method: String, path: String, ctx: Context): DispatchResult {
        let segs = splitPath(path)
        let params = HashMap<String, String>()
        let final = walk(root, segs, 0, params)
        match (final) {
            case Some(node) =>
                let m = method.toAsciiUpper()
                match (node.handlers.get(m)) {
                    case Some(h) =>
                        for ((k, v) in params) {
                            ctx.setParam(k, v)
                        }
                        return DispatchResult.Matched(h)
                    case None =>
                        if (node.anyHandler) {
                            let allow = String.join(collectKeys(node.handlers), delimiter: ", ")
                            ctx.status(405)
                                .header("allow", allow)
                                .header("content-type", "application/json")
                                .body("{\"error\":\"Method Not Allowed\",\"allow\":\"${allow}\"}")
                            return DispatchResult.MethodNotAllowed(allow)
                        } else {
                            ctx.status(404)
                                .header("content-type", "application/json")
                                .body("{\"error\":\"Not Found\",\"path\":\"${path}\"}")
                            return DispatchResult.NotFound
                        }
                }
            case None =>
                ctx.status(404)
                    .header("content-type", "application/json")
                    .body("{\"error\":\"Not Found\",\"path\":\"${path}\"}")
                return DispatchResult.NotFound
        }
    }

    /*
     * Wrap the router as a Middleware. On Matched, run the handler;
     * on MethodNotAllowed/NotFound, respond directly so 405/404 still
     * pass through ctx.commit() and the onError chain untouched.
     */
    public func middleware(): Middleware {
        let r = this
        return { ctx: Context, next: () -> Unit =>
            let result = r.lookup(ctx.method(), ctx.path(), ctx)
            match (result) {
                case DispatchResult.Matched(h) => h(ctx, next)
                case DispatchResult.MethodNotAllowed(allow) =>
                    ctx.status(405)
                        .header("allow", allow)
                        .header("content-type", "application/json")
                        .body("{\"error\":\"Method Not Allowed\",\"allow\":\"${allow}\"}")
                case DispatchResult.NotFound =>
                    if (r.passOnNotFound) {
                        // 透传前必须复位 lookup()
                        // 在 NotFound 路径预写的响应残留 —— status=404、
                        // body、content-type 头。否则后续 handler 的
                        // respondOk()/ctx.json() 只覆盖 body 不改状态码，
                        // 成功响应会带着 404 状态码出门。
                        ctx.resetResponse()
                        next()
                    } else {
                        ctx.status(404)
                            .header("content-type", "application/json")
                            .body("{\"error\":\"Not Found\",\"path\":\"${ctx.path()}\"}")
                    }
            }
        }
    }

    // ---------- internals ----------

    /*
     * Insert one concrete (already expanded) pattern into the trie.
     * Wildcard semantics by position:
     *   trailing "*"     -> greedy tail capture as params["tail"] (legacy)
     *   trailing "*name" -> greedy tail capture as params[name]
     *   mid "*"          -> matches exactly one segment, not captured
     *   mid "*name"      -> matches exactly one segment as params[name]
     */
    func insert(method: String, pattern: String, h: Middleware): Unit {
        let segs = splitPath(pattern)
        var node = root
        let lastIdx = segs.size - 1
        var i: Int64 = 0
        for (seg in segs) {
            let isLast = (i == lastIdx)
            if (seg.size > 0 && seg[0] == 0x2A) { // "*"
                let name = seg[1..]
                if (isLast) {
                    let n = if (name.size == 0) { "tail" } else { name }
                    node = findOrCreate(node, SegmentKind.Wildcard, "*", n)
                } else if (name.size == 0) {
                    node = findOrCreate(node, SegmentKind.Param, ":", "")
                } else {
                    node = findOrCreate(node, SegmentKind.Param, ":", name)
                }
            } else if (seg.size > 0 && seg[0] == 0x3A) { // ":"
                node = findOrCreate(node, SegmentKind.Param, ":", seg[1..])
            } else {
                node = findOrCreate(node, SegmentKind.Static, seg, "")
            }
            i += 1
        }
        node.handlers[method.toAsciiUpper()] = h
        node.anyHandler = true
    }

    func findOrCreate(parent: TrieNode, k: SegmentKind, seg: String, name: String): TrieNode {
        for (c in parent.children) {
            if (c.kind == k && c.segment == seg && (k != SegmentKind.Param || c.paramName == name)) {
                return c
            }
        }
        let nn = TrieNode()
        nn.kind = k
        nn.segment = seg
        nn.paramName = name
        parent.children.add(nn)
        return nn
    }

    /*
     * 按 Static、Param、Wildcard 的优先级匹配，**某个分支走不通时继续尝试
     * 低优先级分支**，而不是直接判定整条路径失败。
     *
     * 为什么需要回溯：注册 /api/users/me 与 /api/:module/list 之后请求
     * /api/users/list，静态段 users 会先命中，但该节点下只挂了 me、没有
     * list。若不回溯就返回失败，本可匹配的 :module/list 会被丢掉，
     * 请求被误判为 404。
     *
     * 回溯时写入的参数必须撤销。同一层的多个参数节点可能写同名键，
     * 失败分支若不复原，取值会污染随后成功的那条分支。
     */
    func walk(node: TrieNode, segs: Array<String>, idx: Int64, params: HashMap<String, String>): ?TrieNode {
        if (idx == segs.size) {
            return if (node.anyHandler) { Some(node) } else { None }
        }
        let seg = segs[idx]
        for (c in node.children) {
            if (c.kind == SegmentKind.Static && c.segment == seg) {
                match (walk(c, segs, idx + 1, params)) {
                    case Some(n) => return Some(n)
                    case None => ()
                }
            }
        }
        for (c in node.children) {
            if (c.kind == SegmentKind.Param) {
                let saved = params.get(c.paramName)
                if (c.paramName.size > 0) {
                    params[c.paramName] = seg
                }
                match (walk(c, segs, idx + 1, params)) {
                    case Some(n) => return Some(n)
                    case None => undoParam(params, c.paramName, saved)
                }
            }
        }
        for (c in node.children) {
            if (c.kind == SegmentKind.Wildcard) {
                let saved = params.get(c.paramName)
                params[c.paramName] = String.join(segs[idx..], delimiter: "/")
                match (walk(c, segs, segs.size, params)) {
                    case Some(n) => return Some(n)
                    case None => undoParam(params, c.paramName, saved)
                }
            }
        }
        return None
    }

    /* 撤销一次参数写入：该键原先有值则还原，原先没有则删除。 */
    func undoParam(params: HashMap<String, String>, key: String, saved: ?String): Unit {
        if (key.size == 0) {
            return
        }
        match (saved) {
            case Some(v) => params[key] = v
            case None => params.remove(key)
        }
    }
}

/*
 * 分组路由：前缀 + 组级中间件的注册便捷层，共享 Router 的单棵 trie。
 * 嵌套 group 继承父组中间件（外层先执行，洋葱语义）。
 */
public class RouteGroup {
    private let router: Router
    private let prefix: String
    private let mw: ArrayList<Middleware>

    init(router: Router, prefix: String, mw: ArrayList<Middleware>) {
        this.router = router
        this.prefix = prefix
        this.mw = mw
    }

    private func fullPath(p: String): String {
        if (p == "/") {
            return prefix
        }
        return prefix + p
    }

    /* 组级中间件包裹 handler：mw 依次执行 → handler → mw 后置回环。 */
    private func wrap(h: Middleware): Middleware {
        if (mw.size == 0) {
            return h
        }
        let chain = ArrayList<Middleware>()
        for (m in mw) {
            chain.add(m)
        }
        let inner: Middleware = { ctx: Context, next: () -> Unit => h(ctx, next) }
        chain.add(inner)
        let composed = compose(chain)
        return { ctx: Context, _: () -> Unit => composed(ctx) }
    }

    public func get(p: String, h: Middleware, name!: ?String = None): RouteGroup {
        router.add("GET", fullPath(p), wrap(h), name: name)
        return this
    }
    public func post(p: String, h: Middleware, name!: ?String = None): RouteGroup {
        router.add("POST", fullPath(p), wrap(h), name: name)
        return this
    }
    public func put(p: String, h: Middleware, name!: ?String = None): RouteGroup {
        router.add("PUT", fullPath(p), wrap(h), name: name)
        return this
    }
    public func delete(p: String, h: Middleware, name!: ?String = None): RouteGroup {
        router.add("DELETE", fullPath(p), wrap(h), name: name)
        return this
    }
    public func patch(p: String, h: Middleware, name!: ?String = None): RouteGroup {
        router.add("PATCH", fullPath(p), wrap(h), name: name)
        return this
    }

    /* 嵌套分组：前缀拼接，中间件链 = 父组 mw + 本次 mw。 */
    public func group(p: String, mw!: Array<Middleware> = Array<Middleware>()): RouteGroup {
        let combined = ArrayList<Middleware>()
        for (m in this.mw) {
            combined.add(m)
        }
        for (m in mw) {
            combined.add(m)
        }
        return RouteGroup(router, fullPath(p), combined)
    }
}

/*
 * Expand optional params (":x?") into concrete patterns.
 *   "/users/:id?"        -> ["/users/:id", "/users"]
 *   "/a/:x?/b/:y?"       -> ["/a/:x/b/:y", "/a/:x/b", "/a/b/:y", "/a/b"]
 * More than 3 optional params in one pattern is rejected (8x expansion cap).
 */
func expandOptional(pattern: String): Array<String> {
    let segs = splitPath(pattern)
    let optIdx = ArrayList<Int64>()
    var i: Int64 = 0
    for (seg in segs) {
        if (seg.size > 2 && seg[0] == 0x3A && seg[seg.size - 1] == 0x3F) {
            optIdx.add(i)
        }
        i += 1
    }
    if (optIdx.size == 0) {
        return [pattern]
    }
    if (optIdx.size > 3) {
        throw IllegalArgumentException("too many optional params (max 3): ${pattern}")
    }
    let out = ArrayList<String>()
    var total: Int64 = 1
    for (_ in optIdx) {
        total = total * 2
    }
    var mask: Int64 = 0
    while (mask < total) {
        let drop = HashSet<Int64>()
        var p: Int64 = 1
        for (oi in optIdx) {
            if ((mask / p) % 2 == 1) {
                drop.add(oi)
            }
            p = p * 2
        }
        let kept = ArrayList<String>()
        var j: Int64 = 0
        for (seg in segs) {
            if (!drop.contains(j)) {
                if (seg.size > 2 && seg[0] == 0x3A && seg[seg.size - 1] == 0x3F) {
                    kept.add(seg[0..(seg.size - 1)])
                } else {
                    kept.add(seg)
                }
            }
            j += 1
        }
        out.add("/" + String.join(kept.toArray(), delimiter: "/"))
        mask += 1
    }
    return out.toArray()
}

func collectKeys(m: HashMap<String, Middleware>): Array<String> {
    let out = ArrayList<String>()
    for (k in m.keys()) {
        out.add(k)
    }
    return out.toArray()
}

/*
 * Split a URL path into segments.
 *   "/"          -> []
 *   ""           -> []
 *   "/users/42"  -> ["users", "42"]
 *   "/a/b/"      -> ["a", "b"]
 */
func splitPath(p: String): Array<String> {
    var s = p
    if (s.size > 0 && s[0] == 0x2F) { // "/"
        s = s[1..]
    }
    if (s.size > 1 && s[s.size - 1] == 0x2F) {
        s = s[0..(s.size - 1)]
    }
    if (s.size == 0) {
        return Array<String>()
    }
    return s.split("/", removeEmpty: true)
}
