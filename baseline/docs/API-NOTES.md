# 服务端 API 事实清单（探针实测）

> 📁 **编译期 API 事实与踩坑记录** ｜ 本文件：`API-NOTES.md` ｜ [全部文档目录](README.md)

> 环境：cjc **1.2.0**（当前基线；下面多数探针是在 **1.1.3** 时期跑的）+ stdx **1.1.3.1** + 轻舟 **`3d6c1a36`**（v0.12.0 之后 6 个提交 = **当前内置快照**，内容由 `MANIFEST.sha256` 每次构建逐字节校验）
> —— ⚠ **以下大量条目写于 `e072980` / `780d5de` 时期**，那些记录保留原样；已被上游修掉的条目（A-1 短读截断、A-4 状态残留、A-5、A-7）**已在上游 v0.12.0（快照 `3d6c1a36`）修复**。那份反馈清单已随反馈闭环删除（2026-10-04）；要看条目原文：`git log --diff-filter=D -- docs/qingzhou-upstream-issues.md`。
> （写于 `e072980` 那次升级的补充：DEF-1 已由上游 `141a735` 修复、本地补丁已撤；上游 `src/store.cj` / `src/rbac.cj` 依赖 CangDB，本项目改用 `fw_rbac_store.cj` / `fw_rbac.cj` 适配并在 `build.ps1` 中排除原版。本次升级同时带进了轻舟自带的**后台管理界面**：`build.ps1 -Target admin`，见 `third_party/qingzhou/PROVENANCE.md`。）
> 方法：`.probe/` 下写了 8 轮最小探针逐个编译验证，**只采用实测通过的签名**。
> 这份清单是为了让后续开发不用重复试错——写代码前先查这里。

---

## 1. 标准库确切签名（实测通过）

### std.fs

```cangjie
File.readFrom(path: String): Array<UInt8>
File.writeTo(path: String, buffer: Array<UInt8>): Unit
File.create(path: String): File            // 用完要 close()
File.appendTo(path: String, buffer: Array<UInt8>): Unit
exists(path: String): Bool                  // 顶层函数，**不是 File.exists**
remove(path: String, recursive!: Bool): Unit
rename(from: String, to!: String, overwrite!: Bool): Unit   // 必须具名传参
Directory.create(path: String, recursive!: Bool): Unit
```

### std.time

```cangjie
DateTime.now().toUnixTimeStamp().toSeconds(): Int64     // 返回 Duration，不是 Int64
DateTime.now().toUnixTimeStamp().toMilliseconds(): Int64
MonoTime.now(); (t1 - t0).toMilliseconds(): Int64
```

- `now.month` 是枚举 `Month`，**不是 Int64**。本项目一律不用本地字段，自己按 epoch 算历法（见 `timex.cj`）。
- 轻舟 `docs/API.md` 已注明：std.time **没有 UTC 工厂方法**。

### std.random

```cangjie
let r = Random()
r.nextBytes(buf: Array<UInt8>): Unit     // ⚠️ 是"填充缓冲区"，不是 nextBytes(n) 取返回值
r.nextUInt64()                            // 未验证，本项目未使用
let buf = Array<UInt8>(n, repeat: 0)
```

### stdx.encoding.hex

```cangjie
toHexString(Array<UInt8>): String
fromHexString(String): ?Array<UInt8>      // 注意返回 Option
```

### stdx.crypto.digest

```cangjie
let md = SHA256(); md.write(bytes); md.finish(): Array<UInt8>
let mac = HMAC(key, { => SHA256() })      // ⚠️ 第二个参数是**工厂 lambda**，不是 SHA256() 实例
mac.write(bytes); mac.finish(): Array<UInt8>
```

- **没有现成的 PBKDF2**：本项目在 `auth.cj` 自行实现（RFC 2898），
  并用 RFC 7914 §11 公开向量 + .NET `Rfc2898DeriveBytes` 双向对拍。
- 100000 次迭代实测 **约 340 ms**（本机）。

### stdx.encoding.json

```cangjie
JsonObject(): 无参构造；o.put(k, JsonValue)；o.get(k): ?JsonValue
JsonArray():  a.add(v)；a.size(): Int64（**方法**）；a.get(i): ?JsonValue
JsonValue.fromStr(s): JsonValue          // 解析失败**抛异常**，不是返回 Option
v.asObject() / v.asString() / v.asInt() / v.asBool()   // 类型不符抛异常
JsonValue.toString()                     // 序列化
JsonString(s) / JsonInt(i) / JsonBool(b) / JsonFloat(f) / JsonNull()
```

- ⚠️ `JsonObject` / `JsonArray` **都不实现 Iterator**，不能 `for (v in arr)`。
  数组按下标 `while` 遍历；本项目落盘用**数组 + 下标**，避免需要枚举 JSON 对象的键。

### std.sort / 集合 / 字符串

```cangjie
sort(arr)                                   // 基础类型默认排序
sort(arr, by!: (T, T) -> Ordering)          // ⚠️ 具名参数是 by，不是 comparator
HashMap<K,V>: m[k]=v；m.get(k): ?V；m.contains(k)；for ((k,v) in m) 元组遍历
HashSet<T>: add / contains
String: .size（**字节数**）、toArray(): Array<UInt8>、String.fromUtf8(bytes)、
        trimAscii()、toAsciiLower()、String.join(arr, delimiter:)、StringBuilder
Int64.parse / UInt16.parse                   // UInt16.parse 需 import std.convert.*
Array: .size 属性、arr[a..b] 切片、arr.clone()
```

### 异常

```cangjie
public class X <: Exception {
    public init(...) {
        super(msg)          // ⚠️ super() 必须是构造函数里**第一条语句**
        ...
    }
}
```
- `Option` **没有 `getOrElse`**，用 `??` 运算符：`opt ?? 默认值`。
- **枚举不支持 `==`**，一律用 `match`（本项目 `perms.cj` 全部如此）。

---

## 2. 轻舟（QingZhou）用法要点

```cangjie
QingZhouApp().use(requestId()).use(logger()).use(bodyParser()).use(cors())
            .use(router.middleware()).use(timeout(15000)).onError(errHandler)
Router().get/post/put/patch/delete/add("/a/:id", { ctx: Context, _: () -> Unit => ... })
ctx.paramOr("id", "")   ctx.requestHeader("authorization")   ctx.bodyJson(): ?JsonValue
ctx.status(200).json(s) / .body(s) / .header(k, v)
ctx.err(): ?Exception                    // onError 链里读
ctx.http → h.request.remoteAddr          // 取客户端地址；⚠️ 实测文本形如 "IP:端口"（例 127.0.0.1:14764），
                                         //    按 IP 用必须先剥端口（见 h_ops.cj 的 clientIpOf）
app.serve(port): ServerHandle            // 非阻塞；handle.wait() 阻塞；handle.shutdown() 优雅关闭
```

- 错误链（`compose.cj`）：业务链抛异常 → `ctx.throw_err(e)` → 执行 `onError` 注册的中间件 → 最后 `ctx.commit()`。
- `serveTls(port, certPem, keyPem)` 收的是 **PEM 字符串**（不是路径）。
  上游 `141a735` 起内部用 `RSAPrivateKey.decodeFromPem`（我们早先那个 `GeneralPrivateKey`
  的本地补丁已随之撤销，不要再打）。

---

## 3. 踩过的坑（**不要再踩**）

| # | 坑 | 现象 / 解法 |
| --- | --- | --- |
| 1 | **crypto 的两个 DLL 必须与 exe 同目录** | 缺失时**编译期无警告**，运行时才 `CryptoException: Can not load openssl library or function SHA256_Init` |
| 2 | **同包编译会撞名字** | 我们与轻舟同一 `package qingzhou`。框架已占用 `pad2`、`verifyPassword`、`hashPassword`、`randomHex`、`randomId`、`sha256Hex`、`bodyStr`、`jsonGetStr`、`exists`、`size`、`get` 等。新增顶层函数前**先 grep 框架源码** |
| 3 | `Directory.create(recursive: true)` 目录已存在**照样抛异常** | 必须先 `exists()` 判断。这个坑会让"第二次落盘"直接崩 |
| 4 | `rename` 的 `to` / `overwrite` 是具名参数 | `rename(a, b)` 编译不过 |
| 5 | `ArrayList` 要 `import std.collection.*` | 忘了就 `undeclared identifier 'ArrayList'` |
| 6 | 源码里出现 `⚠️`（U+26A0 + **U+FE0F**） | 编译器报 `warning: unsecure character:\u{FE0F}`。**去掉变体选择符**即可 |
| 7 | 块注释里不能出现 `/*`（HANDOFF 已记） | 仓颉块注释可嵌套，会吞到文件末尾 |
| 8 | 服务 `cwd` 必须是 exe 所在目录 | 数据目录按相对路径读；`cwd` 不对会出现**假失败 + 假通过** |
| 9 | Windows 无 `std.runtime.Signal` | 优雅关闭只能靠 `POST /admin/shutdown`，**必须限本机** |
| 10 | 在请求线程里直接 `handle.shutdown()` | 会等待本请求自己结束 → **死锁**。要 `spawn` 到后台线程 |
| 11 | **命令行参数里出现非 ASCII，程序直接崩**（2026-09-16 实测） | `club-server.exe init-admin 13800000000 你的密码123 data` → 无输出、exit 1，stderr 只有 `IllegalArgumentException: Invalid unicode scalar value.`。<br>**与参数位置无关**：中文放在口令、手机号或数据目录上都一样 —— 抛在仓颉把 argv 拼成 `String` 的那一步，**早于 `main` 里的任何校验**（切代码页 936 / 65001 都不行）。<br>→ 命令行参数一律用 **ASCII**。口令本身已限定数字/英文/符号（`api-design §2.3` 注 5），手机号是数字，数据目录用英文即可。<br>⚠️ **只影响 CLI**：HTTP 路径是 UTF-8 JSON，中文口令会正常返回 `400 VALIDATION_FAILED`（冒烟 `[26]` 有闸门）<br>**2026-09-17 补充 · 通用绕行办法**：`init-admin` 要传**会长姓名**时因此不能直接写成参数，于是加了 `--name <ASCII 姓名>` 与 **`--name-file <UTF-8 文件>`**（中文姓名走后者；文件内容即姓名，允许带 BOM 与结尾换行，会裁掉首尾空白）。**结论：凡是要把非 ASCII 文本交给 CLI，一律走文件**，别再试着直接塞参数。回归闸门：`tests/init-name-check.ps1`（2026-09-17 当时 **41 项**；2026-10-04 复测为 **45 项**，全绿） |

### PowerShell 脚本（Windows PS 5.1）

| # | 坑 | 解法 |
| --- | --- | --- |
| 11 | 无 BOM 的 UTF-8 `.ps1` 按 **ANSI** 解析 | 中文注释会导致 `Missing closing '}'` 之类的**假语法错**。脚本必须存为 **UTF-8 with BOM** |
| 12 | 执行策略默认禁止跑脚本 | `powershell -NoProfile -ExecutionPolicy Bypass -File xxx.ps1` |
| 13 | 非 2xx 响应读不到 body | `Invoke-WebRequest` 已把流读走，`GetResponseStream()` 拿到空串。用 `$_.ErrorDetails.Message`。**2026-09-16 复现并补充**：写后台端到端脚本时又踩了一次（`$_.Exception.Response.GetResponseStream()` 读出来恒为空串，把"业务码 0"误判成"没响应"）。要**同时**拿 HTTP 状态码和 body 时，直接绕开 `Invoke-WebRequest`：`[System.Net.WebRequest]::Create($url)`（记得 `$req.Proxy = $null`，本机有 `127.0.0.1:7897` 代理），成功/失败都走同一条读流路径 —— 见 `server/tests/admin-check.ps1` 的 `Hit` |
| 33 | **单测的 cwd 必须是 `server/`**（2026-09-16 踩到） | `tests.cj` 里的数据目录写的是 `build/test-data*`，所以要在 `server/` 下执行 `.\build\club-server.exe test`（README 的口径）。若在 `server/build/` 里执行，数据会被写到嵌套的 `build/build/test-data*`，**并且在残留坏数据后第二次运行直接崩在 `testStore`**。这个坑已顺手修掉（`testStore` 现在会先清派生子目录，连跑三次稳定通过），但**cwd 仍必须是 `server/`** |
| 34 | **轻舟的成功响应也可能带 HTTP 404**（2026-09-16，**上游本身的行为，不是我们的 bug**） | 上游统一响应壳把业务码放在 **body 的 `code` 字段**（`0`=成功），HTTP 状态不承载业务语义；而 `passOnNotFound = true` 的路由在 miss 时**先把 `ctx.status` 置成 404**（`router.cj` 的 `lookup()` 会写 ctx），后续真正匹配上的处理器用 `respondOk/respondErr` 时**只写 body、不重设 status**，于是 404 被带到最终响应上：`GET /api/me` 带合法 token → HTTP 404 但 body 是 `{"code":0,...}`。只有**显式设过 status** 的路由才正常（`/health` 就是 200，静态资源也是 200）。实测：上游 `admin-web` 前端是 `fetch(...).json()` 后只看 `code`，所以**界面完全正常**——这也是"上游这套后台确定可用"的原因。**判定归属**：把内置框架的 `src/api.cj` / `src/router.cj` / `src/auth.cj` 与上游 `e072980` 逐字节比对 → SHA-256 全同，所以是上游设计使然。**处置（2026-09-16 晚更新）**：**在我们的入口里修掉了** —— `server/src/ops/admin_main.cj` 的第一个中间件是 `statusNormalizer()`：跑完后面的链后，若 body 以 `{"code":` 开头就按 `code` 回写状态（0→200，其余取 code 本身）。**内置框架一行未改**。<br>**2026-10-02 更新**：上游 **v0.12.0**（快照 `3d6c1a36`）已修本条（`router.cj` 改调新增的 `ctx.resetResponse()`），**现在不会再污染状态码**；我们入口里的 `statusNormalizer()` **保留**（对上游 `examples/` 的示例与外部网关仍成立），原反馈清单的 **A-4** 条目（该清单已删除，见本文开头说明）。现在 `/api/me`、`/api/club/**` 都是 200，拒绝是 401/403（`tests/ops-check.ps1` 有闸门）。**写新测试时仍建议断言 body.code**，因为上游 `examples/admin.cj` 那份示例（只作对照）与外部网关可能不做这一步 |
| 35 | **仓颉 `println` 在 stdout 被重定向到文件时是块缓冲的**（2026-09-16 诊断长驻服务时踩到） | 给 `admin.exe` 里临时加的调试 `println`，用 `Start-Process -RedirectStandardOutput 文件` 之后**一直看不到输出**，容易误判成"这段代码没执行"。同一进程**优雅退出**后日志里那句话才出现（缓冲在进程结束时 flush），而 `Stop-Process -Force` 强杀的进程输出直接丢。**处置**：诊断长驻服务时别依赖 `println` + 文件重定向，改用 ①把诊断信息塞进 HTTP 响应体、②写 stderr、③走优雅关闭路径让缓冲区落盘。本轮最终靠"把事实写进探针服务的响应 JSON"一次定位到根因 |
| 36 | **`POST /admin/shutdown` 的回执可能丢**（2026-09-16 做运维页时实测，**已修**） | 现象：客户端拿到 `HTTP 200` + **空 body**（文档里写的是 `{"ok":true,"data":{"status":"shutting-down"}}`）。根因：`handleShutdown` 先 `sendOk` 再 `spawn { h.shutdown() }`，而 `ServerHandle.shutdown()` 里的 `server.close()` 只负责停止 accept + 收尾，**不等本请求的响应写出去** → 关停线程先于响应写完把连接关了。概率实测：连跑 8 次里 **6 次空体**（跟库大小、客户端、有没有带 body 都无关，纯竞态）。**排查陷阱**：curl 与 .NET 都复现，且**时好时坏**，很容易被当成客户端/网络问题；`smoke.ps1` 的 §23 只断言状态码（200）与"进程自行退出"，所以一直没暴露。**已修**：关停线程改为 `sleep(Duration.second * 1)` 之后再 `h.shutdown()`（`server/src/main.cj`）——Windows 上没有信号机制，这个端点是唯一的关停入口，宁可晚 1 秒关也要让回执可靠。修后连测 6/6 都拿到回执，进程照常优雅退出。回归闸门：`tests/ops-check.ps1` 断言关停响应体是 `ok:true` |
| 37 | **仓颉的块注释会嵌套：注释里出现 `/*` 或 `/**` 会吞掉后面整个文件**（2026-09-16 又踩一次） | 报错是 `error: unterminated block comment`，指向注释**开头那一行**，看起来像"注释没写 `*/`"。真正的原因是注释正文里出现了 `/*` 序列，被当成嵌套注释的开头。本轮两次命中：① `` `server/src/*.cj` ``（反引号里带斜杠星号）；② 描述接口路径时写的 `**/api/club/**`（其中 `/**` 就是斜杠+星号）。**处置**：注释里别写 `/*`、`/**`、`/*.cj` —— 换成 `src` 下的 `*.cj`、`「/api/club/…」` 这种写法。（`docs/HANDOFF.md` §6 的坑表里早有一条同源记录，本次是它在**我们自己的新文件**里复发） |
| 38 | **仓颉枚举不能用 `==` 比较**（2026-09-16 写 ops 权限分支时踩到） | `if (a == TransferPresidency) { ... }`（`a: Action`）编译报 `invalid binary operator '==' on type 'Enum-Action' and 'Enum-Action'`，并提示"要实现 `operator func ==`"。这个枚举没派生等号运算符 —— **改用 `match`**：`match (a) { case TransferPresidency => ...; case _ => ... }`（`perms.cj` 里原本就全是 match 写法，我这次图省事写了 `==`）。**注意字符串不受影响**：`role == "ops"` 是合法的 |
| 39 | **框架 `Context.bodyBytes()` 把"短读"当 EOF → 请求体在约 4 KB 处被截断**（2026-09-18 定位并已就地修复） | 上游 `src/context.cj` 的读取循环里有一句 `if (n < 1024) { loop = false }`：socket 的 `read()` 可以在数据还没到齐时返回**少于请求的字节数**，而这里把它当成了 EOF，于是整个请求体只读到第一次短读为止。**症状极具误导性**：JSON 解析失败 → `/api/v1/auth/login` 报 `{"error":"Invalid JSON body"}`（HTTP 400），而**任务创建**这类走 handler 的端点直接变成 **500 INTERNAL**，看起来完全像业务代码 bug。**实测**：一个完全合法的任务创建请求体（标题 198 B + 描述 4000 B，两头都在 `limits.cj` 上限内）**连打 6 次全部 500**；阈值实测在 3899~3999 B 之间（与业务无关，纯传输）。**已修**：删掉那 3 行，改由 `n <= 0` 判 EOF；清单按索引重算，属**本仓库唯一的框架本地补丁** —— 归属、升级注意事项见 `third_party/qingzhou/PROVENANCE.md`「本地补丁」。修后 2243~60242 B 全部正常送达，70010 B 仍被应用层闸门 413 挡住。<br>**2026-10-02 更新**：上游 **v0.12.0**（快照 `3d6c1a36`）已修本条，**本仓库的本地补丁已撤**，`PROVENANCE.md` 的「本地补丁」一节随之删除 —— 上面"删掉那 3 行"的记录只描述 2026-09-18~10-02 之间的状态。 |
| 40 | **BOM 丢失的第三次实证：shell 的"按行切分重写"也会剥掉 BOM**（2026-09-18） | 坑 26 已记过两次（文件编辑工具、局部编辑）。本次是第三种触发方式：用 `[IO.File]::ReadAllLines()` + `[IO.File]::WriteAllLines($f, $lines, [Text.UTF8Encoding]::new($false))` 做**按行替换**（为了绕开 CRLF 多行匹配），`server/tests/smoke.ps1` 的 BOM 被静默剥掉（HEAD 有、改后无）。症状照旧：`[Parser]::ParseFile` 报 **57 处**"意外的标记"（全是中文乱码引出的假语法错误），而**同一份内容用显式 UTF-8 读入再 `ParseInput` 则是 0 错误** —— 这正是"报错指向文件、真因在编码"的典型形态。**判据**：`(git show HEAD:<path> > tmp)` 后比 `EF BB BF`，或直接 `ReadAllBytes()[0..2]`。**规律**：只要写回时用了 `UTF8Encoding($false)`，就必须先确认原文件本来没有 BOM |
| 41 | **框架 `bodyJson()` 把 `body()` 放在 `try` 之外 → 请求体不是合法 UTF-8 时返回 500 而不是 400**（2026-09-20 独立复核发现，已在应用层补住） | `third_party/qingzhou/src/context.cj` 的 `bodyJson()`：`let raw = body()`（内部 `String.fromUtf8`）**在 try 之外**，`try` 只包住 `JsonValue.fromStr(raw)`。于是**非 UTF-8 的字节**让 `fromUtf8` 先抛，异常绕过 `_bodyJsonError` 一路穿到链尾 `onError` → **HTTP 500 `{"ok":false,"error":{"code":"INTERNAL"}}`**（服务端日志里是一次"服务端错误"，客户端完全看不出是自己编码发错了）。框架 bodyParser 的 `opts.onError` **接不住这一类**（它只覆盖 413 与"JSON 语法错"），`bodyForm()` 的 urlDecode、`text/*` 的 `body()` 同样以 `fromUtf8` 收尾，同病。<br>**触发方式很常见**：PowerShell 5.1 的 `Invoke-RestMethod -Body <字符串>` 在没有 `charset` 时**按系统 ANSI(936) 发中文**（见坑 16）—— 服务端收到 GBK 字节，回 500。<br>**处置（`server/src/limits.cj` 的闸门 ④）**：在 bodyParser **之前**先用 `ctx.bodyBytesCapped(64 KiB)` 做**带上限的流式读**（顺带把"Content-Length 说谎"也挡成 413），再按 Content-Type 触发一次解码把异常接在应用层，统一回 **400 `INVALID_JSON`**。框架源码一行未改（快照逐字节校验 + N-20 的清单纪律）。<br>**回归闸门**：`tests/smoke.ps1` §27.10/§27.11（GBK 编码的 JSON body → 400 且走项目信封）。**这也值得回报上游**（原反馈清单已删除；上报时引用本文坑 41）。 |
| 42 | **`$home` 是只读自动变量**（2026-09-20 写 `dev-serve.ps1` 时实测） | 想用 `$home` 存"MariaDB 根目录"→ 运行即报 `Cannot overwrite variable HOME because it is read-only or constant`（`VariableNotWritable`）。同类还有 `$host`，它更坑：**赋值不报错但被静默忽略**，拿到的仍是 PowerShell 的 host 对象。脚本里一律用自己的名字（`$mhome` / `$srvHost`） |
| 43 | **`.ps1` 里写 C 风格块注释 `/* … */`**（2026-09-20 同一次实测） | PowerShell 的块注释是 `<# … #>`。写 `/*` 时 `Parser::ParseFile` **报 0 个语法错误**（`/*` 被当成一个命令名，语法合法），但一执行就是 `/* : The term '/*' is not recognized…`。教训：**新脚本必须真跑一遍**，静态语法检查通过 ≠ 能跑（仓颉的 C 风格注释写顺手了很容易犯） |
| 44 | **驱动握手把连接字符集写死成 `utf8mb3`(id 33) → 一个 emoji 就让所有写入持续 500**（2026-10-04 定位并已修，**P0**） | 库与 9 张表都是 `utf8mb4`，但**连接侧是 `utf8mb3`**：一条含 **4 字节 UTF-8**（emoji）的记录 INSERT 报 `1366 Incorrect string value`。落盘是**一个事务**，失败即整体回滚，而"已落盘基准" `s.persisted` 只在提交成功后推进 —— 那条坏数据永远留在内存里，**之后每一次写都失败**，直到重启（重启会丢掉所有未落盘的写入）。实测那一刻：emoji 任务 → 500，紧接着普通 ASCII 任务 → 500，纯中文任务 → 500；而 `GET /tasks` → **200**（读的是未落盘的内存：内存 4 条、库里只有 **1** 行）。**触发面不需要认证**：注册时的姓名就是自由文本。<br>**根因**：`server/third_party/mariadb-driver/src/protocol/client_handshake_response.cj:156-161` 的 `getDefault()` → `.setCharset(33)`；框架 `third_party/qingzhou/src/db_mysql.cj:40-67` **没有字符集参数**（只在 `noBackslashEscapes` 为真时发一句 `SET SESSION sql_mode`）；全仓也没有任何 `SET NAMES`。<br>**处置**：`server/src/mysql_store.cj` 建连后**立刻** `db.exec("SET NAMES utf8mb4", Array<DbValue>())`（驱动与框架快照都被 `MANIFEST.sha256` 锁死、不该改，所以修在我们自己的文件里）；设置失败直接抛出，不静默继续。<br>**回归闸门**：MySQL 往返测试里的 4 字节字符断言（`testMysqlRoundTrip`：标题 `"2026 招新🙂"`，并核对字节数 15）—— 把 `SET NAMES` 撤掉这条当场红（已双向验证）。⚠ **不给 DSN 时它会被跳过**。<br>**值得回报上游**（原反馈清单的 **C-8**；清单已删除，上报时引用本文坑 44）：驱动不该把握手字符集写死成 33，框架也该给一个 charset 开关或主动发 `SET NAMES`。 |
| 45 | **PS 5.1 的 `-Body <字符串>` 默认按 ISO-8859-1 编码** | `Invoke-RestMethod` / `Invoke-WebRequest` 传**字符串** body 时，Windows PowerShell 5.1 用 ISO-8859-1（不是 UTF-8）编码 —— **中文载荷到达服务端就是乱码**。必须传 `byte[]`：`-Body ([Text.Encoding]::UTF8.GetBytes($json))`，并把 `-ContentType` 写成 `application/json; charset=utf-8`。<br>**为什么值得单独记**：`server/tests/ai-e2e.ps1` 长期用字符串 body 发中文提问，而本地桩**根本不看内容**，所以测试一直全绿 —— 这条链路的「中文能完好穿过」**从来没被真正验证过**。直到 2026-10-06 打**真实模型**才暴露：`/ai/ask` 的回答是「您没有提供具体的提问内容」。已修 `ai-e2e.ps1` 的 `CallAi` 与登录两处；新增的 `ai-real.ps1` 沿用字节写法 |
| 46 | **`CertificateVerifyMode.Default` 的可用性是平台相关的：Windows 必然失败、Linux 可用** | Windows 上它读不到信任库，必然 `unknown CA(134)`（`spike R5` 实测）；**Linux 上它会读系统信任库，握手是通的** —— 2026-10-06 在 **WSL Ubuntu 26.04 + cjc 1.2.0** 实测：`Default` 打 `api.deepseek.com` / `baidu` / `github` / `bing` **四个公网站点全部通过**（`trustall` 与 `customca` 同样通）。<br>**为什么值得单独记**：这条一度被写成「与 OS 无关、两个平台都要自备 CA」—— 理由是「OpenSSL 不读系统证书库」听上去平台无关，但那只是**推测**；随后被上面的实测**推翻**。**教训：平台差异必须实测，不能从「理由听上去通用」推出来。**<br>**但 `club-server` 仍然一律要求 `--ai-ca`**（`aiValidate` 为了在 Windows 上早失败而统一检查）⇒ **Linux 上也要给，填系统那份即可**：`--ai-ca /etc/ssl/certs/ca-certificates.crt` |
| 14 | `Start-Process -PassThru` 拿不到 `ExitCode` | 用"进程自行退出 + 日志收尾行"作为优雅关闭的证据 |
| 15 | `$args` 是自动变量 | 函数里不要用 `$args` 做局部变量名 |
| 16 | **`-Body` 传字符串会按 ANSI 发送** | 中文请求体到达服务端就是乱码（表现为"改名字成功了但名字没变"）。必须 `[System.Text.Encoding]::UTF8.GetBytes($json)` + `Content-Type: application/json; charset=utf-8` |
| 17 | 响应里的中文比较 | 配合上一条：请求体乱码时，返回的中文自然也对不上，容易被误判成服务端 bug |
| 18 | `ConvertFrom-Json` 单元素数组会退化成对象 | 断言 `.Count` 在 PS 5.1 下对单对象返回 1，可用但要心里有数 |
| 19 | **cjenv 切换 SDK 会打断本项目的构建** | 它会改写 `CANGJIE_HOME` 并把 shims 塞进 PATH。若 `CANGJIE_HOME` 指向别的 SDK（如 1.0.5）而 PATH 里的 `cjc` 仍是 `D:\Cangjie` 的 1.1.3，就会出现**前端 1.1.3 + 后端 LLVM 1.0.5** 串台：`LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func … opt.exe 崩溃`。看起来像编译器 bug，实际是环境串台。`build.ps1` 现在**按版本挑**（优先 1.1.x，因此会跳过 cjenv 的 1.0.5），编译前把 `CANGJIE_HOME`/`PATH` 钉到选中的那套，并在版本不符时先打 `WARNING`；显式传错路径也会被告知而不是静默忽略（2026-09-16） |
| 20 | **`.`NET 正则替换里 `$_` 是特殊记号** | `[regex]::Replace($t, 模式, "...$_.Exception.Message...")` 中的 `$_` 会被替换成**整个输入串**，把文件写坏（本次真把 `tls-check.ps1` 写坏了）。改用字面量 `.Replace()`，或避开 `$_` |
| 21 | **`curl` 是 `Invoke-WebRequest` 的内置别名** | 自定义函数取名 `Curl` 会被别名覆盖（PowerShell 解析顺序：别名 > 函数 > cmdlet > 外部程序），于是悄悄调用到了 `Invoke-WebRequest`。改名 `CurlReq` |
| 22 | **PS 5.1 的 `Invoke-WebRequest` 在自签 HTTPS 上会失败** | 报「基础连接已经关闭: 发送时发生错误」，而**同一时刻** curl、`openssl s_client`、`.NET HttpWebRequest`、原始 `SslStream` 全部正常（HTTP 下 `Invoke-WebRequest` 也正常）。因此 TLS 校验统一改用 curl + openssl，避免把客户端怪癖误判成服务端缺陷 |
| 23 | **原生命令参数里的双引号会被吃掉** | `curl -d '{"a":"b"}'` 里的引号在 PS 5.1 传参时被剥离，服务端收到非法 JSON（表现为 400）。改用 `--data-binary @临时文件` |
| 24 | **openssl / curl 往 stderr 写日志** | 脚本若用 `$ErrorActionPreference = "Stop"`，会把「原生命令写了 stderr」当成致命错误直接中断。用 `Continue` + 显式断言 |
| 25 | **部署包里带着私钥** | `server/dist/club-server/certs/key.pem` 与 `server/certs/key.pem` 都必须在 `.gitignore` 里；`git check-ignore -v <路径>` 自检 |
| 26 | **局部编辑会让 `.ps1` 丢掉 BOM** | 第 11 条讲的是"新脚本要带 BOM"，这里补上更隐蔽的一半：**已经正常的脚本被局部改写后 BOM 会消失**（多数工具默认写无 BOM 的 UTF-8）。下一次运行时整个文件按 ANSI 解析，中文变乱码，报出 `意外的标记"build\smoke-data"`、`表达式或语句中包含意外的标记` 这类**看起来像手写语法错误**的解析失败——很容易误判成"脚本改坏了"。判定：`[System.IO.File]::ReadAllBytes($p)[0..2]` 是否为 `EF BB BF`。改完 `.ps1` 必须确认 BOM 仍在。**2026-09-14 实测补充**：用**文件编辑工具**（不是 shell）对 `smoke.ps1` 做局部编辑，BOM **同样会丢**（编辑前 `EF BB BF`、编辑后没有），已手动补回 —— 所以"只要不用 shell 处理就没事"是错的，**任何局部编辑之后都要查一遍**。**2026-09-14 第二次实证**：同样的编辑方式改 `server/build.ps1`（加中文注释）后 BOM 再次消失，运行时直接报 `Missing closing '}'`（解析失败），补回 BOM 即恢复 |
| 27 | **不要用 PowerShell 双引号字符串处理 `.md` / `.cj` / `.ps1` 的内容** | 双引号里反引号是转义引导符：反引号 + `r` → CR、+ `a` → BEL、+ `t` → TAB、+ `n` → LF。markdown 里的代码跨度（如 `` `restore-member` ``、`` `router.middleware()` ``）**正好全部命中**，于是反引号与首字母被静默吃掉，行被拆断或塞进不可见控制字符——本次真把 `docs/code-review.md` 写坏（2 个裸 BEL 字节 + 3 行残缺重复片段）。改用文件编辑工具，或用**单引号**字符串（单引号里反引号不是转义符）。改完自检非法控制字符（脚本见 `docs/code-review.md` 的 N-2 条） |
| 28 | **`Get-Content` 读 UTF-8 无 BOM 的中文文件会丢行** | PS 5.1 不带 `-Encoding UTF8` 时按 **ANSI** 解码：某些 UTF-8 中文字节落在 GBK **前导字节**区间（0x81–0xFE），会把紧跟其后的 `0x0A` 当成第二字节**吞掉**，两行被并成一行 —— 于是**行数统计与内容都不可信**。实测：`docs\HANDOFF.md` 真实 **371** 行，`(Get-Content).Count` 只报 **283**；`docs\frontend-brief.md` 真实 **256** 行，只报 **222**。读文本一律用 `Get-Content -Encoding UTF8`，或直接用文件工具；字节级检查（`[System.IO.File]::ReadAllBytes`）不受影响 |
| 29 | **注释里的 `⚠️` 会触发仓颉 `unsecure character` 警告** | 仓颉对 **U+FE0F（变体选择符）** 报 `warning: unsecure character:\u{FE0F}` —— 就是"带 emoji 变体选择符的 `⚠️`"（两个码位：U+26A0 + U+FE0F）。它只是警告（`-Woff unused` 不覆盖 parser 警告），但会弄脏构建输出，且以后可能收紧成错误。**注释里写 `⚠`（单码位），别写 `⚠️`。** 实测：`server/src/fw_rbac_store.cj` 文件头用了 `⚠️` → 报 1 warning，去掉后构建输出干净（2026-09-14） |
| 30 | **PS 5.1 里 `System.Net.Http` 默认没加载** | `New-Object System.Net.Http.HttpClient` 直接报 `Cannot find type [System.Net.Http.HttpClientHandler]: verify that the assembly containing this type is loaded` —— .NET 4.x 把 `System.Net.Http` 放在**独立程序集**，Windows PowerShell 5.1 启动时不会自动加载它。先 `Add-Type -AssemblyName System.Net.Http`（PowerShell 7 自带，不需要）。**用途**：写并发基准时要"真并发"发请求，`Start-Job`/`Start-Process` 起进程太重、会把测量本身污染掉，用 `HttpClient` + `PostAsync`/`SendAsync` 收集 `Task` 再 `[System.Threading.Tasks.Task]::WaitAll(...)` 才是干净的墙钟计时。注意默认会走系统代理（本机 `127.0.0.1:7897` 代理挂掉时直接连不上），要设 `$handler.UseProxy = $false`。见 `server/tests/bench.ps1` |
| 31 | **打包出来的 `.cmd` 编码 + 控制台代码页** | 两件事叠在一起会让人以为"程序输出坏了"：① `Set-Content -Encoding ASCII` 会把 .cmd 里的中文注释整行变成 `?`；② `cmd.exe` 默认按 ANSI（中文 Windows = GBK，代码页 936）读 `.cmd`，而仓颉程序往控制台写的是 **UTF-8** 字节，于是一双击启动脚本，服务端的中文日志/报错全是乱码。处置：.cmd 用 `[IO.File]::WriteAllText(..., [Text.Encoding]::Default)`（ANSI）写，并在 `@echo off` 之后加 `chcp 65001 >nul`（`build-package.ps1` 已如此，2026-09-16） |
| 32 | **覆盖"正在运行"的 exe 会报 `Permission denied`** | `ld.lld: error: failed to write the output file: Permission denied` 极易被误判成 SDK 权限/杀软问题，其实是 `club-server.exe` 还在跑（Windows 不允许写入正在执行的 exe）。`build.ps1` 现在会在编译前自查输出文件是否被占用，并直接打印处置命令（2026-09-16） |

---

## 5. 环境级故障：本机仓颉 exe 启动即崩（2026-09-13 晚，**已定位到具体更新**）

**现象**：**所有**仓颉可执行文件启动即崩——本项目 exe、轻舟框架 exe、`cjenv.exe`，
以及 1.0.5 / 1.1.3 两套 SDK 的产物，一律 `exit=-1073741819`（`0xC0000005` 访问违例）。
用一个"进 `main` 就写文件"的探针确认：**`main()` 根本没执行**；stdout 全空（缓冲未 flush，
所以短命令"没有输出"是假象）。长驻服务同样起不来（`/health` 连不上）。

### 5.1 根因（证据链）

| 环节 | 证据 |
| --- | --- |
| **触发点** | 事件日志 `Microsoft-Windows-WindowsUpdateClient` ID 19：**21:40:35 "Installation Successful: 2026-09 预览更新 (KB5124010) (26300.xxxx)"**，紧随 21:40:13 的开机 |
| **时间对照** | 当日 13:58 时 M2 的 165 项冒烟测试**全绿**；21:40 重启 + 该更新之后全崩 |
| **崩溃位置** | 事件日志中故障模块恒为 `C:\WINDOWS\System32\msvcrt.dll`，偏移恒为 `0x62f1e`；自行解析 PE 导出表得知该偏移落在 **`wcslen`**（起始 `0x62ED0`，函数内 +0x4E） |
| **关键反证** | 用 WinSxS 里更新前的 `msvcrt 10.0.26100.8875` 与更新后的 `10.0.26100.9444` 逐字节对比：**`wcslen` 的机器码完全相同**（同 RVA、288 字节全同）。所以**不是 msvcrt 自身被改坏**，而是运行时所处的环境变了 |
| **不是 CRT 通病** | `curl.exe` / `certutil.exe` / `where.exe` 等同样用 msvcrt/ucrt 的程序**全部正常** → 只有仓颉运行时的启动路径踩中 |
| **没有第三方干扰** | WER 的 `LoadedModule` 列表里只有系统 DLL + 仓颉运行时，无注入；`AppInit_DLLs` 为空；无 AppCompat shim |

**已排除**：与本项目代码无关（空 hello world 同样崩）· 与 SDK 版本无关（1.0.5 与 1.1.3 都崩）·
与目录 / 路径长度 / PATH / `CANGJIE_HOME` / 干净环境无关 · `msvcrt` 是 **KnownDLL**
（同目录放同名 DLL 无效；拷全 51 个运行时 DLL 也无效）。

**没有可升级的仓颉版本**：官方下载中心当前 **LTS = 1.0.5、STS = 1.1.3**，
**1.1.3 已是最新稳定版**（仅有 Nightly Builds 可试）。

### 5.2 结论

**这是 Windows 更新 KB5124010（2026-09 预览更新）与仓颉 1.1.3 原生运行时的兼容性问题**，
不是本项目代码问题。仓颉运行时（DLL 构建于 2025/7/30）在这个新的 Windows 补丁级别上
在 `main` 之前就走到了非法内存访问。

### 5.3 处置建议与**验证结果**

1. ✅ **实测有效：卸载 KB5124010**（预览更新，属可选更新）：设置 → Windows 更新 → 更新历史记录 →
   卸载更新，重启即可恢复。**我们已在 2026-09-13 22:18 按此恢复开发。**
2. 若必须保留该更新：**换一台机器**验证/开发；同时把本页的证据反馈给仓颉团队
   （[UsersForum](https://gitcode.com/Cangjie/UsersForum/overview)），附上 `msvcrt!wcslen+0x4E`、
   KB 编号，以及下面"唯一变化的是 ntdll"这一收窄结论。
3. 也可以试 **Nightly Builds** 的 SDK（`gitcode.com/Cangjie/nightly_build/releases`），
   但那是非稳定通道，本项目基线是 1.1.3。

### 5.4 受控 A/B：卸载更新后立即恢复

**同一台机器、同一套仓颉 1.1.3、同一份 `msvcrt.dll`**，卸载 KB5124010 并重启后完全反转：

| 指标 | 故障时（UBR 26300.9539） | 卸载后（UBR 26300.9445） |
| --- | --- | --- |
| 最小 hello world | ❌ `0xC0000005`，无输出 | ✅ `exit 0`，正常输出 |
| `club-server.exe test`（单测） | ❌ 崩（`main()` 未执行） | ✅ **PASS 197 / FAIL 0** |
| `tests\smoke.ps1`（真实 HTTP） | ❌ 服务起不来 | ✅ **PASS 220 / FAIL 0** |

**唯一版本发生变化的已加载模块是 `ntdll.dll`**：

| DLL | 故障时 | 卸载后 | 变化 |
| --- | --- | --- | --- |
| **`ntdll.dll`** | **10.0.26100.9539** | **10.0.26100.9278** | ✅ |
| `msvcrt.dll` | 7.0.26100.9444 | 7.0.26100.9444 | — |
| `ucrtbase.dll` / `msvcp_win.dll` | 10.0.26100.9444 | 10.0.26100.9444 | — |
| `KERNEL32.DLL` / `KERNELBASE.dll` | 10.0.26100.9278 | 10.0.26100.9278 | — |

→ 这解释了"`msvcrt!wcslen` 机器码一字未改却崩在那里"的反常：**变的是 ntdll（加载器）**。
怀疑范围应收窄到**加载器与该版本仓颉运行时的交互**。

> **更正**：早前我们把"`PendingFileRenameOperations` 非空"当作"系统更新未收尾"的证据。
> 卸载后**运行正常时该项依然非空**，该判据不成立，特此更正。

> 完整缺陷报告（可直接提交给仓颉团队）**已移出仓库**，见上层
> `cangjie-upstream\cangjie-runtime-startup-crash.md`；
> 当时的证据包（4 份 WER 崩溃报告、事件日志、PE 对照输出）是一次性产物，已按需删除；
> 结论都固化在本文档里。

---

### 5.5 复现记录：2026-09-16 该更新**再次**被装上，同一崩溃回归

| 证据 | 值 |
| --- | --- |
| 更新事件（`WindowsUpdateClient` ID 19） | **2026-09-16 09:35:18 `KB5124010 (26300.9539)` 安装成功**（与 5.1 里 09-13 21:40 那次同一个 KB） |
| `Win32_QuickFixEngineering` | `KB5124010 InstalledOn = 2026/9/16` |
| `C:\Windows\System32\msvcrt.dll` | **7.0.26100.9444**（修复后是 `.8875`） |
| 崩溃签名 | `Faulting module: msvcrt.dll (7.0.26100.9444)`、`0xc0000005`、`offset 0x62f1e` —— 与 5.1 的 `wcslen+0x4E` 同处 |
| 波及范围 | **今天新编的 exe 崩**，同时**轻舟 9/11 与 9/13 编的 exe 也崩**（同一个 exe 在 9/13 是好用的） |

**A/B 反证（本次新做，用来排除"是不是我们改了构建"）**：同一份 `server\build.ps1`，
只把框架输入从**仓库内置目录**换回**仓库外 `E:\cangjie\qingzhou`**（`-Vendor` 参数），
两份 exe 的崩溃**完全一致** → 与本项目代码、与"框架内置还是外置"都无关，纯环境问题。

**处置与结果**：与 5.3 相同 —— **卸载 KB5124010**。**2026-09-16 当天执行，无需重启即恢复**：
本项目 exe 立刻可跑，四套验证全绿：**单测 387 / 冒烟 360 / TLS 22 / 跨仓契约 30**。

> ⚠️ 一项反直觉、值得记下的观察：卸载后 `msvcrt.dll` 的**文件版本仍然是 `7.0.26100.9444`**
> （并没有回到修复后的 `.8875`），而崩溃已经消失 —— 再次印证 5.1 的结论
> **崩溃不是 msvcrt 自身的字节**引起的，触发点随该 KB 的其它组件一起被撤掉。
> **下次复发时不要用 msvcrt 版本号判断"修好没有"：直接跑一次 exe 最可靠。**

> ⚠️ 这是**同一个可选预览更新第二次**打断本项目的运行时。只要它还在"可选更新"里就可能被再次装上；
> 建议在 Windows 更新里**把它隐藏/暂停**，或固定一台不装它的机器专门做构建与验证。

## 4. 重新探针的方法

需要验证新 API 时，照这个模式做（**不要盲写**）：

```powershell
$CJC  = "D:\Cangjie\bin\cjc.exe"
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
& $CJC probe.cj --import-path $STDX -L $STDX @libs -lcrypt32 -Woff unused -o probe.exe
```

探针验证过的事实请**回写进本文档**，并把探针文件删掉（一次性）。
