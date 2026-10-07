package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 输入上限：请求体大小闸门 + 文本字段长度口径（2026-09-17 新增）。
 *
 * 为什么要在应用侧自己拦一道（框架的 bodyParser 已经有 maxBytes = 1 MiB）：
 *   · 轻舟的 bodyParser 是**先把整个 body 读进内存、再比 maxBytes**
 *     （third_party/qingzhou/src/bodyparser.cj 的 handleJson：`ctx.bodyJson()` 先执行，
 *      之后才 `if (raw.size > opts.maxBytes)`）——所以 1 MiB 那道闸**挡不住**
 *     "发一个 1 GB 的 body 把内存打满"，它只是事后报 413；
 *   · 而且它对**非** json / x-www-form-urlencoded / text 的 Content-Type 直接透传、
 *     不读也不判（同文件 67-80），而 handler 里的 `reqObj(ctx)` 照样会把整个 body
 *     读完（context.cj 的 bodyBytes：先把整份 body 堆进 ArrayList，**之后**才比 maxBytes）
 *     —— 注意读取本身在 2026-09-18 前还有一处 bug：它把一次"短读"当 EOF，请求体在约 4 KB 处
 *     就被截断（合法请求直接 500）。我们已在快照里就地修掉，见
 *     `third_party/qingzhou/PROVENANCE.md`「本地补丁」。**升级上游时要重做那个补丁**，
 *     否则本节这道闸门挡得住"超大 body"，却挡不住"4 KB 以上被截断"。
 *   框架源码是**上游快照**：build.ps1 用 MANIFEST.sha256 逐字节校验，改动会被拒绝构建
 *   （N-20 的教训）。所以按"我们的改动一律落 server/src"的既定做法，在**最外层**加一道：
 *   （2026-09-18 例外：`context.cj` 的短读 bug 已在快照里就地修掉，清单随之重算 ——
 *    这类"确有必要的框架补丁"要按 PROVENANCE.md「本地补丁」的约定记录并重做。）
 *     ① 写方法（POST/PUT/PATCH/DELETE）：Content-Length 超上限 → 413；
 *     ② Content-Type 不在我们认识的三类里 → 415（否则它正好绕过 ①）；
 *     ③ 长度不可判定（Transfer-Encoding / 非数字 Content-Length）→ 411；
 *     ④（2026-09-20 补）请求体不是合法 UTF-8 → 400，而不是 500 —— 见下面 ④ 的注释。
 *   都排在 bodyParser **之前**（见 main.cj 的装配顺序），所以大 body 进不了内存
 *   （④ 用的是带上限的流式读，不是"先读后判"）。
 *
 * ⚠ 能力边界（写清楚，别高估）：**长度不可判定**的请求本闸门一律拒绝（`Transfer-Encoding`
 *   存在、或 `Content-Length` 不是纯十进制数字 → **411 LENGTH_REQUIRED**），
 *   所以"发个 chunked 请求绕过去"这条路已经堵上（2026-09-18 修，原先非数字时静默放行）。
 *   仍未覆盖的是**读方法**（GET/HEAD/OPTIONS）带 body 的情形 —— 那不走本闸门，
 *   只能靠框架那道"先读后判"兜底。要彻底解决得改框架或换服务器，不在本轮范围。
 *
 * 文本字段长度口径也集中在这里：这些字段最终整份进 db.json，而**每次写都要重写整个库**
 * （约 3 倍文件大小的 IO）。不设上限时，一条 1 MiB 的 desc 会被反复重写，而且它一条就顶
 * 上千条正常任务 —— 上限本身就是"库别被单条记录撑爆"的保险丝。
 */

import std.convert.*
import stdx.encoding.json.*

/* 请求体上限。本项目最大的合法请求体是批量分配（200 个 id ≈ 3 KB），64 KiB 留足余量。 */
public let MAX_BODY_BYTES: Int64 = 64 * 1024

/* 文本字段上限（单位**字节**：Cangjie 的 String.size 就是字节数，一个中文约 3 字节）。 */
public let MAX_TITLE_BYTES: Int64 = 200
public let MAX_DESC_BYTES: Int64 = 4000
public let MAX_BLOCKER_BYTES: Int64 = 1000
public let MAX_NAME_BYTES: Int64 = 64
public let MAX_CLIENT_TOKEN_BYTES: Int64 = 64
/* AI 问答的提问上限（AI-8，2026-10-05）：AI 接口原先**没有任何长度闸门**，
   而提问会**原样进 prompt 发给外部模型**（既是费用也是越权输入面）。 */
public let MAX_QUESTION_BYTES: Int64 = 1000

/*
 * 字段长度校验（**收集器版**）：与别的字段问题一起收齐再抛，让表单能一次性逐字段提示
 * —— 与 jsonw.cj 的 `V` 同一口径，所以走 V 的 handler 用它。
 */
public func lenCheck(v: V, field: String, label: String, value: String, limit: Int64): Unit {
    v.check(field, value.size <= limit, "${label}最多 ${limit} 字节（一个中文约 3 字节）")
}

/*
 * 字段长度校验（**立即版**）：给不走 V 的 handler 用（它们本来就是"逐条校验 + 立即抛"的形状）。
 */
public func requireLen(field: String, label: String, value: String, limit: Int64): Unit {
    if (value.size > limit) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField(field, "${label}最多 ${limit} 字节（一个中文约 3 字节）"))
    }
}

/*
 * 请求体闸门。挂在 bodyParser **之前**（main.cj 的 buildApp），见文件头注释。
 *
 * 为什么不直接 throw ApiError 交给 onError：本中间件在 router 之外，直接构造标准错误响应
 * 更短、也少一次异常穿越（错误响应形状与 sendError 完全一致，客户端不用写特例）。
 */
public func bodyLimit(): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let m = ctx.method()
        let writes = (m == "POST" || m == "PUT" || m == "PATCH" || m == "DELETE")
        if (writes) {
            /* ① 长度必须**可判定**，否则闸门形同不存在：
             *   · 带 Transfer-Encoding（chunked）→ 没有 Content-Length，本闸门无从判断；
             *   · Content-Length 不是纯十进制数字 → 同样判不了。
             *   这两种都**明确拒绝**，不给"绕到框架那边先读进内存"留口子。
             *   （2026-09-18 修：原先非数字时静默放行，chunked 请求可原样绕过本闸门。） */
            match (ctx.requestHeader("transfer-encoding")) {
                case Some(te) =>
                    if (!isBlank(te)) {
                        sendError(ctx, apiErrMsg("LENGTH_REQUIRED",
                            "请用 Content-Length 声明请求体长度（本服务不接受 chunked）"))
                        return
                    }
                case None => ()
            }
            match (ctx.requestHeader("content-length")) {
                case Some(raw) =>
                    if (!isDigits(raw)) {
                        sendError(ctx, apiErrMsg("LENGTH_REQUIRED",
                            "Content-Length 必须是十进制数字"))
                        return
                    }
                    /* 先判位数再 parse：`Int64.parse` 遇到 20 位以上的数字会**抛异常**（溢出），
                     * 而这里是中间件最外层，异常会变成 500 —— 一个"报 413"的闸门反被超长
                     * Content-Length 打成 500。15 位十进制（10^15）早就远超 64 KiB，直接按
                     * "过大"处理即可，不必解析。 */
                    var over = (raw.size > 15)
                    if (!over && Int64.parse(raw) > MAX_BODY_BYTES) {
                        over = true
                    }
                    if (over) {
                        sendError(ctx, apiErrMsg("PAYLOAD_TOO_LARGE",
                            "请求体过大（上限 ${MAX_BODY_BYTES} 字节）"))
                        return
                    }
                case None => ()
            }
            /* 空 Content-Type 视为"没有 body"（例如 DELETE），放行。
             * 其余只认文本/表单/JSON 三类 —— 框架的 bodyParser 认它们，
             * 而这之外的类型会绕过它的读取路径（见文件头）。
             * 大小写不敏感（RFC 7231 §3.1.1.1）：ctx.contentType() 只剥参数、不转小写，
             * 所以统一 toAsciiLower() 后再比
             * （2026-09-18 修：原先 Application/JSON 会被误判 415）。 */
            let ct = ctx.contentType().toAsciiLower()
            if (ct.size > 0 && ct != "application/json" &&
                ct != "application/x-www-form-urlencoded" && !startsWithAscii(ct, "text/")) {
                sendError(ctx, apiErrMsg("UNSUPPORTED_MEDIA_TYPE",
                    "请求体格式不受支持，请使用 application/json"))
                return
            }
            /*
             * ④ 请求体必须是**合法 UTF-8**（2026-09-20 补；由一次独立复核发现）。
             *
             * 症状：一个客户端把 JSON 按 **GBK/ANSI** 编码发过来（PowerShell 5.1 的
             *   `Invoke-RestMethod -Body <string>` 在没有 `charset` 时就是这么干的），
             *   服务端返回 **500 INTERNAL / 服务端错误** —— 而它本该是 400。
             *
             * 根因在框架里（context.cj 的 bodyJson）：
             *     let raw = body()          // ← String.fromUtf8(bodyBytes())，**在 try 之外**
             *     try { JsonValue.fromStr(raw) } catch (e) { _bodyJsonError = Some(e) }
             *   非 UTF-8 的字节让 `String.fromUtf8` 先抛出，异常绕过 `_bodyJsonError`、
             *   一路穿到链尾的 onError → 500。框架的 bodyParser 因此**接不住这一类**，
             *   它那个 `opts.onError`（我们已换成项目信封）只覆盖 413 与"JSON 语法错"。
             *   同理 `bodyForm()` 的 urlDecode 与 text 的 `body()` 也是 `String.fromUtf8` 收尾。
             *
             * 为什么在**应用侧**补、而不是改快照：框架源码是上游快照，build.ps1 逐字节校验
             *   （MANIFEST.sha256），改动会被拒绝构建；本项目既定做法是"我们的改动一律落
             *   server/src"（见文件头与 PROVENANCE.md）。这条也值得回报上游。
             *
             * 做法：在**能接住异常的这一层**把 body 的解码提前做掉。
             *   · 先 `bodyBytesCapped`：**不是**先把整份 body 读进内存（那正是本闸门要避免的），
             *     而是流式读到上限就停 —— 于是"Content-Length 说谎、实际远超 64 KiB"也被挡成 413；
             *   · 它同时把字节写进框架的 body 缓存，所以后面 bodyParser / handler 复用同一份，
             *     "InputStream 只消费一次"的约束不破；
             *   · 再按 Content-Type 触发对应的解码。JSON 的**语法错**由框架内部捕获
             *     （走 _bodyJsonError → 400），所以这里 catch 到的只可能是**编码错**。
             * ⚠ 只对写方法生效（GET 带 body 不走本闸门，见文件头的能力边界）。
             */
            match (ctx.bodyBytesCapped(MAX_BODY_BYTES)) {
                case None =>
                    sendError(ctx, apiErrMsg("PAYLOAD_TOO_LARGE",
                        "请求体过大（上限 ${MAX_BODY_BYTES} 字节）"))
                    return
                case Some(_) => ()
            }
            try {
                if (ct == "application/x-www-form-urlencoded") {
                    let _ = ctx.bodyForm()
                } else if (ct == "application/json") {
                    let _ = ctx.bodyJson()
                } else {
                    let _ = ctx.body()
                }
            } catch (e: Exception) {
                sendError(ctx, apiErrMsg("INVALID_JSON",
                    "请求体不是合法 UTF-8 —— 请用 UTF-8 编码，并在 Content-Type 里带上 charset=utf-8"))
                return
            }
        }
        next()
    }
}

/*
 * 框架 bodyParser 的错误响应**不走我们的信封**（它自己写 `{"error":"..."}`，
 * 既没有 ok 也没有 error.code），客户端按 code 分支时会踩空。
 * 这里把它的 onError 换掉，统一成 api-design §1.3 的形状
 * （2026-09-18 修，见 main.cj 的 .use(bodyParser(...))）。
 */
func bodyParserOnError(ctx: Context, status: Int64, msg: String): Unit {
    if (status == 413) {
        sendError(ctx, apiErrMsg("PAYLOAD_TOO_LARGE", "请求体过大（上限 ${MAX_BODY_BYTES} 字节）"))
    } else {
        sendError(ctx, apiErrMsg("INVALID_JSON", "请求体不是合法 JSON"))
    }
}

/* 给 main.cj 用的 bodyParser 选项（onError 换成上面那个）。 */
public func bodyParserOptions(): BodyParserOptions {
    let o = BodyParserOptions()
    o.onError = bodyParserOnError
    return o
}
