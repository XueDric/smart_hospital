package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.7 · 部门招募链接 —— 3 个接口
 *
 * 设计要点（api-design §3.7）：
 *   · 招募链接**只做部门预填**，不赋予任何角色；通过它注册的人仍是 pending
 *   · **链接不免除注册口令**：单一门槛。链接是便利，口令才是准入
 *   · 每个部门可以有多个链接（"2026 秋招" / "补录"），便于分别停用
 */

import std.collection.*
import stdx.encoding.json.*

/*
 * 招募链接的 scheme 与可选前缀 —— 由 main.cj 在启动时按启动形态设置：
 *   · `serve`      → INVITE_URL_SCHEME = "http"
 *   · `serve-tls`  → INVITE_URL_SCHEME = "https"
 *   · 给了 `--public-url http://10.194.17.0:8080` → INVITE_URL_BASE 用它（优先级最高）
 *
 * 为什么做成"启动时设置"的包级变量、而不是每次请求去猜：
 * 请求本身看不出"这个连接是不是 TLS"（框架的 Context 没暴露），而框架的 HTTP 服务与
 * HTTPS 服务是**两个不同的启动分支** —— 谁起的服务谁最清楚，让它写下来最省事、也最准。
 * 默认 "http"：本项目**联调就是明文**，默认值必须让最短路径能用（生产用 serve-tls，
 * 会显式覆盖成 https）。
 */
public var INVITE_URL_SCHEME: String = "http"
public var INVITE_URL_BASE: String = ""     /* 非空 = 完整前缀，如 http://10.194.17.0:8080（不含结尾斜杠） */

/*
 * 链接落地页地址。用请求的 Host 头拼，避免把域名写死进配置。
 *
 * L-2 已知取舍：接口文档里这个 URL 是要发到群里的"落地页"，但原先**没有 /join/{token}
 * 这个路由**，点开就是 404；而且 Host 头是调用方可控的，响应里的 url 会被污染
 * （只在调用方自己的响应里，不落盘、不影响他人，所以定为低危）。
 * 现在补上了落地页（handleJoinLanding），Host 头的问题保留并记录：
 * 真正上线时应改为配置项（服务端已知自己的公网地址）。
 *
 * ⚠ 2026-09-22 修一个把"招募链接"彻底搞坏的问题：**scheme 原先硬编码成 https**。
 *   我们本机联调跑的是 `serve 8080`（明文 HTTP），于是发到群里的链接是
 *   `https://10.194.17.0:8080/join/xxx` —— 浏览器拿 TLS 去敲一个 HTTP 端口，
 *   结果就是**"无法连接"**（在模拟器内置浏览器里同样，因为端口本身说不了 TLS）。
 *   现在 scheme 跟着启动形态走（`serve` → http、`serve-tls` → https），
 *   见下面的 INVITE_URL_SCHEME（由 main.cj 在启动时设置）。
 *
 * 另一个坑是 host：它取的是**请求头 Host**，也就是"客户端连服务端时用的那个地址"。
 * 模拟器里 `DEV_BASE_URL=http://10.0.2.2:8080` → 生成的链接就是 `http://10.0.2.2:8080/join/xxx`，
 * 那个地址**只有模拟器自己能解析**，复制到 PC 浏览器或发给队友都打不开。
 * 要做"发群里大家都能点"，就用 `--public-url http://<你的局域网IP>:8080` 显式指定前缀。
 */
func linkUrl(ctx: Context, token: String): String {
    /* ① 显式指定的前缀优先（--public-url，去掉结尾斜杠后原样使用） */
    if (INVITE_URL_BASE.size > 0) {
        return "${INVITE_URL_BASE}/join/${token}"
    }
    /* ② 否则按"客户端连进来的那个地址"拼，scheme 跟启动形态一致 */
    let host = ctx.requestHeader("host") ?? "localhost"
    return "${INVITE_URL_SCHEME}://${host}/join/${token}"
}

/*
 * GET /join/{token} —— 招募链接的落地页（无需登录，L-2）。
 *
 * 客户端是 HarmonyOS 应用：浏览器点普通 http(s) 链接通常只打开本页，
 * 页内再用 clubmanager://join/{token} 按钮唤起 App（v1 的自定义协议桥接）。
 * 因此这里给一个**最小可用**的说明页：告诉用户链接属于哪个部门、下一步该做什么。
 * 只暴露部门名——那本来就是链接持有者能看到的信息，不含任何口令、成员或任务数据。
 */
public func handleJoinLanding(ctx: Context, s: Store): Unit {
    let token = ctx.paramOr("token", "")
    var deptName = ""
    s.lock.lock()
    try {
        match (s.invite_links.get(token)) {
            case Some(l) =>
                if (l.enabled) {
                    match (s.departments.get(l.dept_id)) {
                        case Some(d) => deptName = d.name
                        case None => deptName = ""
                    }
                }
            case None => ()
        }
    } finally {
        s.lock.unlock()
    }
    let html = if (deptName.size > 0) {
        joinPageHtml(
            "加入「${deptName}」",
            "点击下面的按钮打开社团管理 App；注册页会自动带出该部门。若未安装 App，请先安装。",
            "clubmanager://join/${token}"
        )
    } else {
        joinPageHtml(
            "链接已失效",
            "这个招募链接已被停用或不存在，请向管理员索取新的链接。",
            ""
        )
    }
    /* N-9：落地页是本项目唯一一处 HTML 输出，加一行 CSP。
     * 该页只有内联 style 属性、没有脚本也没有外部资源，所以 default-src 'none'
     * 不会破坏显示；即使将来哪一处漏了转义（N-1），注入的脚本也执行不了。 */
    ctx.header("content-type", "text/html; charset=utf-8")
        .header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'")
        .status(200)
        .body(html)
}

/* 落地页 HTML：不用模板引擎，也不引入任何外部资源（离线可看）。
 *
 * N-1：title / tip 一律先过 htmlEscape —— 页面上要显示部门名，而部门名只校验过
 * "非空"，直接拼接就是一个 HTML 注入点。转义在这里做（而不是调用处），
 * 将来谁再往这两个参数里塞用户数据也自动是安全的。 */
func joinPageHtml(title: String, tip: String, appUri: String): String {
    let t = htmlEscape(title)
    let p = htmlEscape(tip)
    let button = if (appUri.size > 0) {
        "<p><a href=\"${htmlEscape(appUri)}\" style=\"display:inline-block;padding:.75rem 1.25rem;" +
            "background:#155DFC;color:#fff;text-decoration:none;border-radius:8px;font-weight:600\">" +
            "打开 App 并继续注册</a></p>"
    } else {
        ""
    }
    return "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
        "<title>${t}</title></head>" +
        "<body style=\"font-family:sans-serif;padding:2rem;line-height:1.8;color:#222\">" +
        "<h2>${t}</h2><p>${p}</p>${button}" +
        "<p style=\"color:#888;font-size:.9rem\">社团管理工具</p>" +
        "</body></html>"
}

/*
 * 生成不与现有链接冲突的 token（**16 字节 = 32 个十六进制字符**）。
 *
 * N-19：原先是 `randHex(4)`（4 字节 = 32 bit），而 `GET /join/{token}` 免认证、
 * 命中就返回部门名 —— 32 位空间可以枚举（配合并发是小时级）。
 * 链接本身不免除注册口令（"链接是便利，口令才是准入"），所以危害有限；
 * 但没必要留这个缺口：与会话令牌（32 字节）同口径更省心。
 * 重试循环保留（现在第一次必然成功），上限不动。
 */
func freshLinkToken(s: Store): String {
    var i: Int64 = 0
    while (i < 64) {
        let t = randHex(16)
        if (!s.invite_links.contains(t)) {
            return t
        }
        i += 1
    }
    /* 极端情况退化为更长 token，绝不返回重复值 */
    return randHex(32)
}

/*
 * 招募链接 → 部门预填（D-16，2026-09-16）。
 *
 * **由服务端从 token 推导，不信任客户端自报的 dept_id** —— 这是 D-16 方案 2 的核心：
 * 客户端只要把用户点进来的那个 token 原样带上，部门由服务端说了算。
 * 链接不存在 / 已停用 / token 形态不对 → 0（预填为空）。
 *
 * 纯函数式（只读 Store 的两张表），因此可以在单测里直接覆盖"停用链接不给部门"这类反例。
 */
public func resolveInviteDept(s: Store, token: String): Int64 {
    if (token.size == 0 || token.size > 64) {
        return 0
    }
    match (s.invite_links.get(token)) {
        case Some(l) =>
            if (l.enabled) {
                return l.dept_id
            }
            return 0
        case None => return 0
    }
}

/*
 * GET /api/v1/join/{token} —— 招募链接的**公开 JSON 解析**（D-16 方案 1）。
 *
 * 为什么需要它：链接是发到群里的 http(s)://<host>/join/<token>，浏览器先打开落地页；
 * 用户从页内 clubmanager://join/<token> 唤起 App 后，App 拿到 token，
 * 没有任何免认证的途径把 token 换成一个 `dept_id` —— 落地页只回 HTML。
 * 没有这个端点，P12 的「来自于招募链接的部门预填」就只能靠客户端自报部门，链路不闭环。
 *
 * 响应形状与落地页语义一致：**链接不存在与已停用返回同一个 200 形状**
 * （`dept: null, enabled: false`），客户端据此渲染「链接已失效」，
 * 不必为"有没有 data.dept"写特例（与 §3.7 停用接口的 L-3 口径同源）。
 *
 * 只暴露部门名与启停状态 —— 那本来就是链接持有者能看到的信息，不含口令、成员或任务。
 */
public func handleJoinResolve(ctx: Context, s: Store): Unit {
    let token = ctx.paramOr("token", "")
    s.lock.lock()
    try {
        var deptId: Int64 = 0
        var enabled = false
        if (token.size > 0 && token.size <= 64) {
            match (s.invite_links.get(token)) {
                case Some(l) =>
                    if (l.enabled) {
                        enabled = true
                        deptId = l.dept_id
                    }
                case None => ()
            }
        }
        let data = JsonObject()
        if (deptId > 0) {
            jPutObj(data, "dept", deptBriefObj(s, deptId))
        } else {
            jPutNull(data, "dept")
        }
        jPutBool(data, "enabled", enabled)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/dept-invite-links */
public func handleInviteLinkList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    s.lock.lock()
    try {
        let list = ArrayList<DeptInviteLink>()
        for ((_k, l) in s.invite_links) {
            list.add(l)
        }
        let arr0 = list.toArray()
        sortByKey<DeptInviteLink>(arr0, { l: DeptInviteLink => l.created_at * 1000 + l.dept_id })
        let arr = JsonArray()
        for (l in arr0) {
            arr.add(inviteLinkView(s, l, linkUrl(ctx, l.token)))
        }
        let data = JsonObject()
        data.put("items", arr)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/dept-invite-links */
public func handleInviteLinkCreate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    let body = reqObj(ctx)
    let v = V()
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.done()

    let data = JsonObject()
    storeMutation(s, { =>
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let l = DeptInviteLink()
        l.token = freshLinkToken(s)
        l.dept_id = deptId
        l.enabled = true
        l.created_by = actor.id
        l.created_at = nowEpoch()
        s.invite_links[l.token] = l
        jPutObj(data, "link", inviteLinkView(s, l, linkUrl(ctx, l.token)))
        /* 也把 token/url 提到顶层，方便客户端直接用（api-design §3.7 的响应示例） */
        jPutStr(data, "token", l.token)
        jPutStr(data, "url", linkUrl(ctx, l.token))
    })
    sendCreated(ctx, data)
}

/*
 * DELETE /api/v1/dept-invite-links/{token} —— 停用链接（**不是删除记录**）
 *
 * 语义是"停用"：记录保留、enabled 置 false，便于在列表里看到"已停用的秋招链接"。
 * **幂等**：对不存在或已停用的 token 重复调用一律返回 200——
 * 与 assign 同理，客户端重试不该产生错误。
 */
public func handleInviteLinkDisable(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ManageInviteLink, Target())
    let token = ctx.paramOr("token", "")
    if (token.size == 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("token", "缺少链接标识"))
    }
    /*
     * ⚠ 这里**故意不做长度校验**（2026-09-17 复核后撤掉了原先那个 128 字节上限）。
     *
     * 原先的理由是"超长 token 会被原样拼进审计行"，但那条路走不到：审计行只在
     * `s.invite_links.get(token)` **命中**时才写，而库里的 token 只由 freshLinkToken()
     * 产出（16 字节 = 32 位十六进制，极端回退 32 字节 = 64 位，见本文件上方），
     * 所以超长 token 永远匹配不到任何记录 —— 它必然走下面的 goneLink 分支，
     * 既不会被写进审计，也不会碰任何数据。
     *
     * 而加那道 400 会**破坏本函数自己的幂等契约**（见上方注释与 L-3：不存在 / 已停用的
     * token 一律 200 + 完整视图，客户端不必写特例）：同一个"不存在的 token"只因为长度
     * 超过 128 就变成 400，前端反而要多一个分支。长度上限在这里没有收益、只有契约代价。
     */
    s.lock.lock()
    try {
        match (s.invite_links.get(token)) {
            case Some(l) =>
                l.enabled = false
                storeSave(s)
                audit(s, actor.id, "disable-invite-link", l.dept_id, "token=${token}")
                sendOk(ctx, inviteLinkView(s, l, linkUrl(ctx, token)))
            case None =>
                /* 幂等：不存在也返回成功。
                 * L-3：响应形状必须与存在时一致——原先返回空对象 {}，
                 * 客户端读 data.link.enabled 会拿到 null，得写一个"有没有 data.link"的特例。
                 * 这里给同一个视图，字段齐全、enabled 恒为 false。 */
                sendOk(ctx, inviteLinkView(s, goneLink(token), linkUrl(ctx, token)))
        }
    } finally {
        s.lock.unlock()
    }
}

/* 为"已不存在"的链接造一个同形状的替身：token 原样回显、enabled=false、其余为空。 */
func goneLink(token: String): DeptInviteLink {
    let l = DeptInviteLink()
    l.token = token
    l.dept_id = 0
    l.enabled = false
    l.created_by = 0
    l.created_at = 0
    return l
}
