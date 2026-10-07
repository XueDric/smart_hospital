# 服务端大模型出站调用框架 · 要求

> 📁 **AI 出站调用规范** ｜ 本文件：`llm-client-spec.md` ｜ [全部文档目录](README.md)

> **工具链基线**：**cjc 1.2.0**（cjnative, x86_64-w64-mingw32）+ **stdx 1.1.3.1** + 轻舟 **`3d6c1a36`**（v0.12.0 之后的 HEAD）快照 · 同包编译
> **前置证据**：`spike/llm-http/FINDINGS.md`（五项能力已实测）· `spike/semaphore/probe.cj`（信号量已实测）
> **本版变更**：工具链基线由 1.1.3 升至 **1.2.0**（2026-10-01 决定），全文按新基线重梳并补入验证结论
> **状态（2026-10-06 更新）**：**需分层读**。
>
> **已实现并验证**：「出站客户端 + 5 个智能接口」这一层 —— `server/src/ai_transport.cj` /
> `ai_client.cj` / `ai_config.cj` / `ai_schema.cj` / `h_ai.cj`（4 个 handler + 路由）。
> 2026-10-05 接通，随后经**三轮审查修复**；当前状态以 `docs/ai-module-review.md` **§9.7** 为准。
> **本文此前记的四处偏差已全部修复**：**R-6**（重试归零时把退避一起删了）·
> **R-9**（固定窗口 → 滑动窗口：慢调用原本可绕过限流）·
> **R-10**（`TooLarge` 独立分类）· **R-11**（审计补齐 `status` 与 `endpoint 主机名`）。
>
> **部分实现**：`dispatchAiTool` 与工具循环（§5.6 / §14 的 T 系列）已落地**只读**版本
> —— `POST /api/v1/ai/agent`：5 个只读工具、轮数 ≤ 4、整个请求共享 20 s 预算、denied 落审计。
> **写操作已做 L1**（2026-10-06）：三段式「模型提议 → 用户确认 → 服务端执行」已落地，
> 只开 `set_my_task_status`（改**自己**负责的任务状态）；L2/L3 未开，**L3 永久排除**。
> 另外：**真实模型联调已跑通**（打公网模型，`/ai/ask`、`/ai/agent`、`/ai/task-suggest`
> 三个接口全部 `source=model`；`/ai/agent` 实测 rounds=2 / calls=2）。
> **§14 的完整验收清单仍未做。**
>
> **§10.2 的单测已补**（2026-10-06）：`tests.cj` 的 `testAi()` 覆盖 **U1–U6 / U8–U11**
> 以及后续几轮修出来的回归点（F-1 / F-6 / F-7 / R-1 / R-8 / R-9 / R-10）——
> 单测总数 512 → **541**。其中 **U7 是人工评审项**（"写锁函数内不得出现出站调用"，
> 见 `docs/code-review.md`），**U12（信号量分两批）**仍以 `spike/semaphore/probe.cj`
> 为证据、未进单测。
>
> **与本文措辞的已知差异**（有意为之，逐条见审查报告）：单次补全上限做成可配
> `--ai-max-tokens`（默认 2048）而非硬编码；"被 token 上限截断"归独立的 `truncated`
> 且**不重试**（**F-7**）；AI 未配置时 `source` 发 `fallback` 而非 `none`（**R-8**）。

---

## 0. 这份文档是什么

「任务全生命周期智能体」需要服务端主动**出站**调用大模型 API。本文规定这一层的：

- 工具链基线（§2）与硬约束（§3）
- 模块边界与文件布局（§4）
- 对外接口（Cangjie 签名级，§5）
- 并发与锁纪律、安全、审计、测试、构建集成（§6–§10）
- 已知坑清单（§11）与分期（§12）

**读者**：实现这个模块的人。**§11 已知坑清单建议先读**。

---

## 1. 目标 / 非目标

### 目标

| # | 目标 |
|---|---|
| G1 | 在仓颉服务端**稳定**调用 HTTPS 大模型 API（TLS 可行性已在 1.1.3 与 1.2.0 两代工具链上验证） |
| G2 | 任何网络/模型故障都**不使 club-server 崩溃、不挂死、不串行化** |
| G3 | 模型输出经**归一化 + 强校验**后才允许进入业务数据 |
| G4 | 智能体的每一次动作**都必须经过 `can()`**，不得绕过权限系统 |
| G5 | 全链路可测试（无网络也能跑单测）、可审计（密钥永不入日志） |

### 非目标

- ❌ 不做通用 HTTP 库（轻舟已有 `httpclient.cj`；本模块只补它缺的 TLS + 大模型语义）
- ❌ 不引入模型厂商 SDK（只走 OpenAI 兼容的 HTTP 协议）
- ❌ 第一期不做流式（SSE）——见 §12
- ❌ 不在客户端直连大模型（**密钥会随 HAP 泄露**，必须服务端代理）

---

## 2. 工具链基线（1.2.0）

### 2.1 基线与配对

| 项 | 值 |
|---|---|
| 编译器 | **cjc 1.2.0**（cjnative, x86_64-w64-mingw32） |
| stdx | **1.1.3.1**（`E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx`） |
| 本机切换方式 | `cjenv use 1.2.0 --persist`（SDK 在 `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie`） |
| 运行时 | 随 SDK：`<SDK>\runtime\lib\windows_x86_64_cjnative` |

**为什么是 cjc 1.2.0 + stdx 1.1.3.1 这个组合**：轻舟上游 v0.10.0 的**发布口径就是 cjc 1.2.0**，
而 stdx 侧仍是 1.1.3.1（`PROVENANCE.md` 第 120-121 行有记载）。这是**升级到上游基线**，不是自选组合。

### 2.2 升级可行性 —— 已实测，**零源码改动**

| 验证项 | 结果 |
|---|---|
| 出站 HTTP/HTTPS spike（R1–R5 全部五项） | ✅ **与 1.1.3 结果逐项一致**（含 `CustomCA` 打通，264ms） |
| `club-server` 全量编译 | ✅ exit=0，产物 **13,317,120 字节** |
| 运维台（`-Target admin`，含框架 `store.cj`）全量编译 | ✅ exit=0，产物 **12,721,664 字节** |
| stdx 1.1.3.1 在 cjc 1.2.0 下 | ✅ 无 LLVM 串台、无 API 破坏 |

> **结论**：1.2.0 升级对本项目**没有编译期破坏**，且升级已在本仓库落地（见 §2.3）。

### 2.3 升级状态：**已完成**（提交 `972f34d` + `2c1620e`）

`build.ps1` 的版本偏好**已从 `1.1.` 改为 `1.2.0`**，并把仓库内固定工具链
`..\.tools\cangjie-1.2.0\cangjie` 放在候选列表最前（clone 后不会被 PATH 上的旧 shim 抢走）。
**2026-10-04 据实更正**：该目录在本检出里**仍不存在**；本机实际是**通过 `CANGJIE_HOME`**
（由 `cjenv` 版本管理器指向它自己的 1.2.0）选中的
`C:\Users\<用户>\.cjenv\sdks\1.2.0\cangjie` —— `PATH` 上的 `cjc` 是 **1.1.3**，正是靠这个版本比对才没被抢走。

Linux 侧脚本（旧 `build.sh` / `setup-linux-env.sh` 等）已随本次升级移出仓库，`server/` 现存 5 个 `.ps1`。

> ⚠ **历史说明**：本 spec 早期版本把「`build.ps1:94` 硬编码只认 `1.1.`，导致升级静默失效」
> 列为阻塞项 **C12**。**该问题已修复，C12 作废**（见 §3 表）。

### 2.4 ⚠ 运行时 DLL 必须与编译器同代

| DLL | 1.1.3 | 1.2.0 |
|---|---|---|
| `libcangjie-runtime.dll` | 1,276,416 B | **1,297,408 B** |
| `libboundscheck.dll` | 44,032 B | 44,032 B |

拿 1.1.3 的运行时跑 1.2.0 编出的 exe 是错配。
`server\build.ps1` 已从 `$CangjieHome\runtime\lib\...` 取（口径正确），
但**手写编译命令时最容易在这里借错**（本 spike 的 build.ps1 就踩过一次，已修）。

---

## 3. 硬约束（违反必返工）

| # | 约束 | 来源 |
|---|---|---|
| C1 | 轻舟 `httpclient.cj` **没有 TLS 入口**，必须直接用 `stdx.net.http` + `stdx.net.tls` | 其文件头 + 原反馈清单 C-6（清单已删除；上游 v0.12.0 已补 `outbound.cj`，见 §14） |
| C2 | 必须 `import stdx.net.tls.*`，否则运行时报 `Global TLS kit is not set` | spike 实测（1.1.3 / 1.2.0 均然） |
| C3 | **Windows** 上 `CertificateVerifyMode.Default` **必然失败** → 必须 `CustomCA`；**Linux 上 Default 可用**（会读系统信任库） | spike R5：Windows `unknown CA(134)`；2026-10-06 WSL Ubuntu 实测 Linux 四站点全通过 |
| C4 | `TlsClientConfig` 必须 `var` 声明后才能赋字段（`let` 报 *cannot assign to immutable value*） | spike 编译期 |
| C5 | `CustomCA` 收 `Array<Certificate>`（接口），且**数组不协变**，`Array<X509Certificate>` 需逐个拷贝 | spike 编译期 |
| C6 | 本工具链的仓颉 std **没有 `getEnv`** → **密钥不能走环境变量**（只能走命令行/配置文件） | `README.md` §5 分钟上手 |
| C7 | 与轻舟**同一个 `package qingzhou`**：顶层函数名会撞车（已被占用：`pad2`/`verifyPassword`/`randomHex`/`bodyStr` 等） | `API-NOTES.md` 坑 3 |
| C8 | 业务数据在 **MySQL**，共享状态由 `Store` 的 Mutex 保护；**对外慢调用绝不能在锁内** | spike R4：8088ms vs 2034ms |
| C9 | `stdx.encoding.json.JsonValue.fromStr` 是**严格**解析器，代码块围栏/前后带话一律失败 | spike R3 |
| C10 | exe 旁边必须有 `libcrypto-3-x64.dll` + `libssl-3-x64.dll`，缺了**编译期无警告**、运行时才炸 | spike + `README.md` 坑 1 |
| C11 | 含中文的 `.ps1` 必须是 **UTF-8 with BOM**（PS 5.1 否则按 GBK 解码吞代码） | 本仓库 15 个脚本全带 BOM |
| ~~C12~~ | ~~`build.ps1:94` 硬编码只认 `1.1.`~~ → **已修复**（现优先 `1.2.0`，见 §2.3） | §2.3 |
| C13 | 运行时 DLL 必须与编译器**同代** | §2.4 |

### 关于 C3 的补充：CA bundle 从哪来

- 生产：随部署包发一份 CA bundle，路径由 `--llm-ca` 指定。
- 本机开发：可临时借 Git 自带的那份
  （`D:\Program Files\Git\usr\ssl\certs\ca-bundle.crt`，229 KB）——**不得**写进代码默认值。
- `TrustAll` **只允许本机开发**，见 §7 S3。

---

## 4. 文件布局与模块边界

```
server/src/
  llm_client.cj      ★ 本模块主文件（build.ps1 的 server/src/*.cj 通配会自动带上）
  llm_json.cj        ★ 模型输出归一化 + 校验（可独立单测，不碰网络）
server/tests/
  llm-check.ps1      ★ 端到端（起桩服务）
  llm-stub.mjs       ★ 桩服务（把 spike/llm-http/stub.mjs 收编，去掉一次性 spike 属性）
```

**布局约束**

1. 必须放在 `server/src/` **根下**——`build.ps1` 取的是 `server/src/*.cj`，**不递归子目录**。
   （运维台那条构建取 `server/src/ops/*`，会与 `jsonw.cj` 撞名的前例见 `README.md`）
2. **不新增 package**——沿用 `package qingzhou`，否则要改构建脚本、还得处理与轻舟的可见性。
3. 新增顶层符号前先做重名检查（C7）：
   ```powershell
   Select-String -Path server\third_party\qingzhou\src\*.cj -Pattern '^\s*(public\s+)?(func|class|struct|enum|interface)\s+<你的名字>'
   ```
   建议统一加前缀 `llm` / `Llm` 降低撞车概率。
4. `std.sync.Semaphore`（§6 P3）来自 **std**，不需要 stdx，**不增加链接负担**。

---

## 5. 接口定义

> 下列签名是**要求**，不是建议。类型名可议，语义与分层不可议。

### 5.1 选项与配置

```cangjie
public class LlmOptions {
    /* 端点：OpenAI 兼容的完整 URL，例如 https://api.deepseek.com/v1/chat/completions */
    public var endpoint: String = ""

    /* 密钥来源：文件路径（C6 —— 不能用环境变量）。文件内容首尾空白会被裁剪。
       绝不接受命令行直接传密钥：会进 ps 历史 / 进程列表。 */
    public var apiKeyFile: String = ""

    /* CA bundle 路径（C3 —— 必填，除非 allowInsecureTrustAll = true） */
    public var caBundlePath: String = ""

    /* 超时：秒。默认 30/30。禁止 0（无限等） */
    public var readTimeoutSecs: Int64  = 30
    public var writeTimeoutSecs: Int64 = 30

    /* 并发上限（见 §6）。默认 4。慢模型不得吃光线程 */
    public var maxConcurrent: Int64 = 4

    /* 允许的重试次数（仅对 isRetryable() 的结果生效）。默认 1（即最多 2 次尝试） */
    public var retryMax: Int64 = 1

    /* 单次请求体上限（字节）。防止把整库内容塞进 prompt */
    public var maxRequestBytes: Int64 = 65536

    /* ⚠ 仅本机开发可用：跳过证书校验。
       为 true 时启动必须打醒目警告，且审计里每次调用都记 insecure=true */
    public var allowInsecureTrustAll: Bool = false

    /* 单次调用的总预算（毫秒），含重试。超预算直接降级，不再尝试。默认 20000 */
    public var budgetMs: Int64 = 20000

    public static func fromFlags(flags: HashMap<String, String>): LlmOptions
}
```

**命令行参数**（沿用 `main.cj:274` 的 `flagOf(flags: HashMap<String, String>, k: String)`，
注意它**只返回 String**——数值参数要自行 `parse` 并校验范围，非法值按启动期错误处理）：

```
--llm-endpoint <URL>
--llm-key-file <PATH>
--llm-ca <PATH>
--llm-timeout <秒>              # 读写共用；必须 > 0，否则拒绝启动
--llm-max-concurrent <N>        # 必须 ≥ 1
--llm-insecure-trust-all        # 仅开发
```

**启动期校验**（fail-fast，不要等到第一次调用才报）：

- `endpoint` 为空 → 智能功能整体置为「未配置」，**但服务照常启动**（不能因为没配大模型就起不来）
- `endpoint` 非 `https://` → 除非 `allowInsecureTrustAll`，否则拒绝（明文调大模型 = 密钥裸奔）
- `caBundlePath` 不存在 → 拒绝启动智能功能并打印**可照做的**提示
- `apiKeyFile` 不存在 → 同上

### 5.2 结果类型与错误分类

**分类必须足够细，否则上层无法决定"重试 / 降级 / 报错"**（这是 spike R2 的直接产物：
超时是"抛异常后被接住"，必须转成可判定的值）。

```cangjie
public enum LlmOutcome {
    | Ok                          // 2xx，body 已完整读完
    | HttpStatus(UInt16, String)  // 非 2xx，原始 body 带回
    | Timeout(String)             // 读 / 写超时
    | Network(String)             // 连接失败 / 读体中断
    | Tls(String)                 // 握手 / 证书校验失败
    | Config(String)              // 选项缺失或非法（不该在运行期出现，属编程错误）
    | TooLarge(String)            // 超过 maxRequestBytes
    | Overloaded(String)          // 并发信号量已满（见 §6 P3）
}

public class LlmResponse {
    public let outcome: LlmOutcome
    public let status: UInt16       // 仅 Ok / HttpStatus 有意义，其余为 0
    public let body: String
    public let elapsedMs: Int64
    public let attempts: Int64

    public func isOk(): Bool
    /* 可重试：Timeout / Network / 429 / 5xx。Tls / Config / TooLarge 一律不可重试 */
    public func isRetryable(): Bool
    /* 供上层拼提示语的一句话原因。**不得包含密钥或完整 prompt** */
    public func reason(): String
}
```

### 5.3 传输层必须是可注入的接口

**理由**：单测不得依赖网络（G5）。这是硬要求，不是风格偏好。

```cangjie
public interface LlmTransport {
    func postJson(url: String, rawBody: String, headers: HashMap<String, String>): LlmResponse
    func close(): Unit
}

/* 真实实现：HTTPS + CustomCA + 超时 + noProxy */
public class HttpsLlmTransport <: LlmTransport {
    public init(opts: LlmOptions)
    public func postJson(...): LlmResponse
    public func close(): Unit
}
```

`HttpsLlmTransport` 的构造**必须**按下述顺序配置（C2/C3/C4/C5 的落地）：

```cangjie
import std.fs.*
import stdx.crypto.common.*      // Certificate 接口
import stdx.crypto.x509.*        // X509Certificate
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*     // C2：少了它运行时报 Global TLS kit is not set

var cfg = TlsClientConfig()      // C4：必须 var
if (opts.allowInsecureTrustAll) {
    cfg.verifyMode = CertificateVerifyMode.TrustAll
} else {
    let pem = String.fromUtf8(File.readFrom(opts.caBundlePath))
    let acc = ArrayList<Certificate>()          // C5：数组不协变，逐个装
    for (c in X509Certificate.decodeFromPem(pem)) { acc.add(c) }
    cfg.verifyMode = CertificateVerifyMode.CustomCA(acc.toArray())
}
let client = ClientBuilder()
    .noProxy()                                            // 见下
    .readTimeout(Duration.second * opts.readTimeoutSecs)
    .writeTimeout(Duration.second * opts.writeTimeoutSecs)
    .tlsConfig(cfg)
    .logger(<压到 ERROR 的 logger>)                        // 见下
    .build()
```

两个必须写进注释的理由（都会静默出问题）：

- **`.noProxy()`**：stdx 默认读系统 `http_proxy`。轻舟自己的注释记过——回环地址也会被代理拦成
  `502 upstream connect failed`。出站调用必须直连。
- **`.logger(...)`**：stdx 超时会往 **stdout** 打 `WARN ... read response timeout`。
  club-server 的 stdout 是运维可见的，必须压到 `ERROR`（照 `third_party/qingzhou/src/app.cj` 里
  `SimpleLogger` + `LogLevel.ERROR` 的写法）。

### 5.4 模型输出归一化与强校验（**C9 的直接产物**）

实测：`JsonValue.fromStr` 对 ` ```json ... ``` ` 和「好的，建议如下：{...}」**一律解析失败**。
而模型输出恰恰最常是这两种形态。因此**必须先归一化再解析**。

```cangjie
public class Extracted {
    public let ok: Bool
    public let text: String     // 归一化后的纯 JSON 文本
    public let reason: String
}

/* 归一化：剥围栏 → 抽第一个「配平的」{...} → 交给 JsonValue.fromStr 试解析。
   必须处理：字符串内的花括号、转义反斜杠、嵌套对象。 */
public func extractJsonPayload(modelText: String): Extracted
```

**归一化实现要求**（每条都要有单测，见 §10）：

| # | 规则 |
|---|---|
| N1 | 剥离首尾 ``` / ```json 围栏 |
| N2 | 从第一个 `{` 起做**括号配平扫描**，正确跳过字符串字面量与 `\"` 转义 |
| N3 | 只取**第一个**配平对象；后面的内容丢弃（模型常爱追加解释） |
| N4 | 归一化后仍解析失败 → `ok = false`，**不抛异常** |
| N5 | 原始文本**不得**直接进业务；只有 `ok = true` 时其 `text` 才允许被解析使用 |

### 5.5 降级契约（**任何智能功能都必须遵守**）

```cangjie
public enum SuggestionSource {
    | Model       // 模型给的
    | Fallback    // 模型不可用，退回规则/历史统计
    | None        // 连兜底都给不出，界面必须显示「暂不可用」
}

public class Suggestion<T> {
    public let source: SuggestionSource
    public let value: ?T
    public let note: String       // 给用户看的一句话，不得泄露内部细节
}
```

| # | 要求 |
|---|---|
| D1 | 智能接口**永不**因模型故障返回 5xx。失败 = `source != Model`，HTTP 仍是 200 |
| D2 | 每个智能接口都必须有一个**不依赖模型的兜底**（规则 / 历史统计）。兜底不得为空 |
| D3 | 连兜底都给不出时 → `source = None`，并在响应里带 `code = LLM_UNAVAILABLE` |
| D4 | **模型输出在任何情况下都不得直接成为写库值**，必须先过 `extractJsonPayload` + schema 校验 |
| D5 | schema 校验失败 → 重试 1 次 → 仍失败即降级。**禁止**把幻觉写进 MySQL |

### 5.6 工具调用与权限（G4 —— 能同时拿「架构分」和「智能分」的设计点）

> **实现状态（2026-10-06）：已实现「只读」那半。**
>
> 落地位置：`server/src/ai_tools.cj` 的 `dispatchAiTool(s, actor, tool, args: JsonObject, now)`
> \+ `server/src/h_ai.cj` 的 `handleAiAgent` → `POST /api/v1/ai/agent`。
>
> · **已做**：T1（唯一入口已收敛）· T2（静态白名单，模型不能新增工具）· T3（参数当不可信输入）
>   · T4（轮数 ≤ 4 + **整个请求共享**的 20 s 预算）· T5（审计，**denied 也落**）· T6（只用 `can()`）
> · **本期只读**：白名单 5 个工具（`list_my_tasks` / `task_detail` / `dept_stats` /
>   `list_dept_open_tasks` / `list_pending_members`）全部只查数据、**无副作用** ——
>   所以 T1 说的"副作用动作"今天还不存在，但**入口已经收敛成唯一一个**，加写操作时不用改结构
> · **签名与本文不同（有意为之）**：本文写 `args: HashMap<String, String>`，实际用 `JsonObject`
>   —— 因为协议是 **JSON-in-content**，参数天然就是 JSON 对象，没必要再摊平成字符串表
> · **denied 的 payload 是中性文案**：不告诉模型缺哪个权限，避免这个接口被当成权限探测面
> · **写操作已做 L1（2026-10-06）**：三段式落地为 `/ai/agent` 的 `proposal` 块 +
>   `/ai/agent/confirm`。令牌存 `idem` 表（`payload` / `used_at` 两列），5 分钟窗口，
>   **执行时重新跑 `can()`**（TOCTOU），失败**不标记已消费**（无副作用发生，可重试）。
>   L2/L3 未开。原设计意图保留如下：**模型提议 → 客户端确认 → 服务端执行** 三段式，
>   每个写工具都要有确认令牌与幂等键；模型**永远不能直接落库**

智能体可以调用现有的 40 个接口，但：

```cangjie
/* 全模块唯一允许执行副作用动作的入口。
   ★ 内部必须调用 can(actor, action, target)；为 false 时直接拒绝，不执行、不重试。 */
public func dispatchTool(actor: Member, tool: String, args: HashMap<String, String>): ToolResult
```

| # | 要求 |
|---|---|
| T1 | **禁止**在 `dispatchTool` 之外执行任何由模型产生的动作 |
| T2 | 工具的白名单是**静态表**：`工具名 → (所需 can() 动作, 参数 schema)`。**模型不能新增工具** |
| T3 | 参数一律当**不可信输入**：走既有 `limits.cj` 的上限闸门与 `jsonw.cj` 的取参校验 |
| T4 | 工具调用的**循环上限**（默认 4 轮）与总预算，超限即停并返回已得结果 |
| T5 | 每次工具调用都写审计：`actor` / `tool` / `allowed` / 结果摘要。**denied 必须记** |
| T6 | 权限判定**只用** `can()`。禁止在 LLM 链路上另写一套 if（会与 `perms.cj` 漂移） |

**架构叙事**（答辩可直接讲）：**智能体不能绕过权限系统**——模型只是"提议"，能否执行由
`can(member, action, target)` 这唯一判定点决定。

---

## 6. 并发与锁纪律（C8）

### 6.1 实测依据

4 线程各做一次 2 秒外部调用（1.1.3 与 1.2.0 两代工具链结果一致）：

| 模式 | 总耗时 |
|---|---|
| 锁内做 I/O | **8088 ms**（1.2.0：8104 ms，完全串行） |
| 锁外做 I/O | **2034 ms**（1.2.0：2040 ms） |

差值 6 秒。这与本项目 PBKDF2 移出全局锁那次是同一个病，而大模型调用**更慢**。

### 6.2 要求

| # | 要求 |
|---|---|
| P1 | **`Store` 的锁之内，禁止出现任何 `LlmTransport` 调用**（含间接调用） |
| P2 | 命名约定：凡以 `Locked` 结尾的函数，评审时**一律检查**其调用链里有无出站调用 |
| P3 | `maxConcurrent` 用 `std.sync.Semaphore` 强制（API 已实测，见 §6.3） |
| P4 | 并发写库照旧走既有两阶段赋值（`code-review.md` N-15 的纪律），智能调用一律发生在**取数 → 调用 → 再回锁写**的三段式里 |
| P5 | 智能调用必须在**请求链末端刷盘之前**完成，避免拖长锁外的落盘窗口 |

### 6.3 `std.sync.Semaphore` —— **已实测（cjc 1.2.0）**

从 `std.sync.cjo` 提取并经运行验证的 API：

```cangjie
import std.sync.*

let sem = Semaphore(4)          // 构造：初始许可数
sem.acquire()                   // amount 有默认值 1
sem.acquire(amount: 2)          // ⚠ amount 是【具名参数】，不能位置传参（acquire(2) 编译报错）
sem.release()
sem.release(amount: 2)
sem.tryAcquire()                // 非阻塞，返回 Bool；取不到【立刻】返回 false
sem.count                       // 只读属性：当前剩余许可
```

**运行实测**（`spike/semaphore/probe.cj`）：

| 场景 | 实测 | 结论 |
|---|---|---|
| `Semaphore(3).count` | 3 | 构造语义正确 |
| 上限 2 / 4 线程 × 300ms | **622 ms** | 两批 → **限流生效** |
| 上限 1 / 3 线程 × 200ms | **616 ms** | 完全串行 → 上限语义正确 |
| 取满后 `tryAcquire()` | `false`，**0 ms** | 非阻塞，可直接用于"过载即降级" |
| `release()` 之后再 `tryAcquire()` | `true` | 归还正确 |
| `Semaphore(4).acquire(amount: 3)` → `count` | 1 → 4 | 批量加减正确 |

**因此 `Overloaded` 的推荐实现**（非阻塞 + 有限等待，避免线程堆积）：

```cangjie
if (!sem.tryAcquire()) {
    // 短暂等待后仍拿不到 -> 直接降级，不排队堆积
    return overloadedResponse()          // LlmOutcome.Overloaded
}
try {
    /* 出站调用：注意此处【不在】Store 锁内（P1） */
} finally {
    sem.release()
}
```

> `tryAcquire` 延迟为 0ms，所以"有限等待"需自行用 `sleep` 轮询；
> 建议上限 300–500ms，超过即 `Overloaded`。**不要**用阻塞 `acquire()` 做无上限排队。

### 6.4 三段式参考形状

```cangjie
/* 1) 锁内：只取数，立刻出锁 */
let snapshot = store.readForLlm(taskId)
/* 2) 锁外：慢调用（可与其他请求重叠）+ 信号量限流 */
let resp = llm.postJson(...)
let sug  = llmJson.validate(resp)
/* 3) 锁内：只写那几行，立刻出锁 */
store.applySuggestion(taskId, sug)
```

---

## 7. 安全要求

| # | 要求 |
|---|---|
| S1 | **密钥绝不入日志**：审计、stdout、错误响应、`reason()` 一律不得含密钥。单测要有一条断言盯着这点 |
| S2 | 密钥只在内存中保留必要的时长；不入库、不出现在任何 API 响应 |
| S3 | `allowInsecureTrustAll = true` 时：启动打醒目警告 + 每次调用审计记 `insecure=true`；**评审环境默认关闭** |
| S4 | endpoint 强制 `https://`（除 S3 的开发模式） |
| S5 | 用户可控文本（任务标题/描述）进 prompt 时**视为不可信**：模型返回的动作仍走 §5.6 的白名单与权限 |
| S6 | 请求体受 `maxRequestBytes` 约束，避免把整库塞进 prompt（也避免费用失控） |
| S7 | 审计记录**不存完整 prompt**，只存长度/摘要/hash，避免敏感内容落盘 |
| S8 | **明文端口保留（已决策，见 §9.3）**：轻舟 `app.serve(port)` 绑 `0.0.0.0` 且**没有只绑回环的选项**（原反馈清单 C-5；清单已删除）→ 该端口在本机开发期**必须由防火墙限制在回环/内网**，公网部署前**绝不转发** |

---

## 8. 可观测性与审计

| 项 | 要求 |
|---|---|
| 每次调用 | 记 `elapsedMs` / `outcome` / `status` / `attempts` / `endpoint 主机名` |
| 每次工具调用 | 记 `actor` / `tool` / `allowed` / 摘要（T5） |
| 落点 | 复用 `server/src/audit.cj` |
| 错误码 | 新增 `LLM_UNAVAILABLE` / `LLM_TIMEOUT` / `LLM_BAD_OUTPUT`。⚠ **本项目规定「`docs/api-design.md` §1.3 是错误码的唯一权威，改 `errors.cj` 之前先改文档」**——顺序不能反。落地方式是在 `errors.cj` 的 `errorSpec(code)` 里增加分支，返回 `(HTTP 状态码, 中文文案)` |
| 状态码 | **业务码仍在 body 的 `code`**（本项目既有约定：HTTP 状态给网络层，`error.code` 给业务层）。智能失败对外返回 **200 + 降级结果**，不占用错误码路径 |
| ⚠ 既有陷阱 | 轻舟 `passOnNotFound` 会在路由 miss 时污染 `ctx.status`，导致**成功响应也可能带 404**（`API-NOTES.md` 坑 34）。新增智能接口要确认状态码正确，别继承这个毛病 |
| 计数 | 建议暴露到运维页 `/api/club/overview`：成功/降级/失败计数（答辩时是很好的演示素材） |

---

## 9. 构建与部署集成

### 9.1 常规要求

| # | 要求 |
|---|---|
| B1 | 不新增构建脚本分支——`build.ps1` 的 `server/src/*.cj` 通配自动带上 |
| B2 | 部署包（`build-package.ps1`）必须额外带：CA bundle + 密钥文件**模板**（不含真密钥）+ 新的 `start-https.cmd` 参数示例 |
| B3 | 4 个 DLL 已在部署清单里（C10/C13）；**升级工具链后必须重新拷贝**，不能沿用旧代的运行时 |
| B4 | 新增的 `.ps1` 必须存成 **UTF-8 with BOM**（C11） |
| B5 | 文档同步：`README.md`（环境事实/坑表）、`docs/API-NOTES.md`、`docs/local-deploy.md` |

### 9.2 工具链升级为 1.2.0：**已完成**

原清单（`build.ps1` 的 `1\.1\.` 偏好、`setup-linux-env.sh` 的 `CJC_VER`/`STDX_VER`、
`build.sh` 版本警告、各处文案）**均已随提交 `972f34d` + `2c1620e` 处理完毕**，
Linux 侧脚本整体移出仓库。

**升级后仍成立的约束**：

| # | 约束 |
|---|---|
| 1 | `build.ps1` 现在**按 `1\.2\.0` 挑**候选 SDK；若机器上只有 1.1.3，会走 `Write-Warning` 后在 `$found` 里退化选择 —— **升级后要确认构建日志打印的版本** |
| 2 | 部署包里的运行时 DLL 必须重新从 `<SDK>\runtime\lib\windows_x86_64_cjnative` 取（C13） |
| 3 | **本机 `server/build/club-server.exe` 是 2026-09-24 的旧产物**，早于升级提交 —— 验证升级成果前必须先重编 |

### 9.3 明文端口：**决策为保留**（本机开发用）

原反馈清单 C-6 记过（清单已删除；上游 v0.12.0 已补出站 TLS）：运维台曾只能走一个**明文端口**调 club-server。
经决定：

> **明文端口先保留** —— 它让本机搭环境、联调、验证都更方便。

因此**不做**改动，但配一条约束（S8）：

- 明文体**只用于本机/内网**，防火墙限制来源；
- **公网部署前必须收口**；收口所需的 HTTPS 出站能力本模块已具备（§5.3 的 `CustomCA` 路径已验证可用），届时运维台改走 HTTPS 即可关闭该端口；
- 不要把它写进任何对外文档/演示材料。

---

## 10. 测试要求与验收标准

### 10.1 分层

| 层 | 位置 | 是否联网 |
|---|---|---|
| 归一化/校验单测 | `server/src/tests.cj` | ❌ 纯函数，注入字符串 |
| 传输层单测 | `server/src/tests.cj` | ❌ 注入**假 `LlmTransport`** |
| 端到端 | `server/tests/llm-check.ps1` + `llm-stub.mjs` | 本地桩，走真 HTTP |

### 10.2 必测用例（U1–U5 直接来自 spike，属回归闸门）

> ⚠ **下表用的是旧名字，实现里已改名**（2026-10-06 标注；写测试时按右边这列找）：
> U1–U5 的 `extractJsonPayload` → 框架的 **`extractJson`**；
> `SuggestionSource.Fallback` → **`AiResult.source == "fallback"`**；
> `LlmTransport` → **`HttpTransport`**（本项目的实现是 `AiTransport`）；
> `allowInsecureTrustAll` → **`insecureTrustAll`**；
> `retryMax` → **`RetryPolicy(maxAttempts)`**（当前取 1，配合外层重试上限 2）。
>
> 落地位置：`server/src/tests.cj` 的 **`testAi()`**。

| # | 用例 | 期望 |
|---|---|---|
| U1 | 合法 JSON | `extractJsonPayload.ok = true` |
| U2 | ```json 围栏包裹 | `ok = true`（**归一化生效**） |
| U3 | 前后带自然语言 | `ok = true` |
| U4 | 截断 JSON | `ok = false`，不抛异常 |
| U5 | 字符串内含 `{` `}` 与 `\"` | 配平扫描不误判 |
| U6 | 假 transport 返回 `Timeout` | 上层得到 `SuggestionSource.Fallback` |
| U7 | 写锁函数内出现出站调用 | ⚠ 人工评审项；建议在 `code-review` 清单里加一条 |
| U8 | 审计输出中不含密钥 | 断言**失败**才算通过（反向闸门） |
| U9 | `allowInsecureTrustAll` 下审计含 `insecure=true` | 通过 |
| U10 | 桩返回 500 / 429 | `isRetryable() = true`，重试次数符合 `retryMax` |
| U11 | 桩返回 401 | `isRetryable() = false`（密钥错重试无意义） |
| U12 | 信号量上限=2，4 个并发请求 | 总耗时 ≈ 两批（**照 `spike/semaphore/probe.cj` 的 T2 写法**） |

### 10.3 纪律（沿用本项目既有口径）

- 单测**不得**依赖网络；桩服务只在 `tests/*.ps1` 端到端里起
- 需要真实 Key 的活体调用：**显式 `-Live` 开关**，默认不跑；且**不静默跳过**——
  要打印醒目的 `SKIP(live)`，避免"以为测了其实没测"
- 判据仍是 **`FAIL 0`**

### 10.4 验收标准（全部可验证）

1. `club-server.exe test` 在**断网**环境下全绿
2. `tests/llm-check.ps1` 在只起本地桩的情况下 **FAIL 0**
3. 手工验证：删掉 CA bundle → 启动打印可照做的提示，**且服务仍能起**、智能功能标记为未配置
4. 手工验证：把 endpoint 改成错的 → 智能接口返回 200 + 降级结果，**不返回 5xx**
5. 手工验证：并发 4 个"生成通知"请求，总耗时 ≈ 单次耗时（**不是 4 倍**）——C8 的回归闸门
6. 全仓库 grep 审计/日志输出，确认无密钥泄漏

---

## 11. 已知坑清单（实现者必读，逐条都真实踩过）

| # | 坑 | 症状 | 处置 |
|---|---|---|---|
| 1 | `CANGJIE_HOME` 指向非预期 SDK | `LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func`，看着像编译器 bug | 编译前显式重写 `CANGJIE_HOME`；**PATH 前置没用**。`cjenv current` 可查当前值 |
| 2 | ~~升级 1.2.0 后"没生效"~~ → **已修复** | 曾因 `build.ps1` 硬编码 `1.1.` 而静默用旧编译器构建（无任何警告） | 现已按 `1.2.0` 挑候选（§2.3）；**构建后仍要核对日志打印的版本** |
| 3 | 运行时 DLL 用错代 | 运行期诡异崩溃 / 加载失败 | 从 `<SDK>\runtime\lib\...` 取（C13） |
| 4 | 无 BOM 的 UTF-8 `.ps1` | 一行赋值**凭空不执行**，脚本语法却是对的 | 存成 UTF-8 **with BOM**（C11） |
| 5 | 缺 `import stdx.net.tls.*` | 运行时 `Global TLS kit is not set` | 显式 import（C2） |
| 6 | 缺 OpenSSL DLL | 运行时 `Can not load openssl library or function CRYPTO_get_ex_new_index` | exe 同目录放 2 个 DLL（C10） |
| 7 | 未 `.noProxy()` | 回环地址被系统代理拦成 `502 upstream connect failed` | 显式 `noProxy()` |
| 8 | 未压 logger 级别 | stdout 被 `WARN ... read response timeout` 刷屏 | `ClientBuilder().logger(...)` 压到 ERROR |
| 9 | `-l:stdx.net.http` 写法 | 被按点号拆开，报 `invalid file or directory '.http'` | 必须 `-l:libstdx.net.http.a` 完整文件名 |
| 10 | `Semaphore.acquire(2)` 位置传参 | 编译报 `missing argument prefix 'amount:'` | 写 `acquire(amount: 2)`（§6.3） |
| 11 | 同包顶层重名 | 编译报重复定义 | 加 `llm`/`Llm` 前缀，先查 `API-NOTES.md`（C7） |

---

## 12. 分期（**P-0 / P0 已完成**；P1 起未开工）

| 期 | 内容 | 出口判据 |
|---|---|---|
| ~~P-1~~ | ~~工具链升级到 cjc 1.2.0~~ | ✅ **已完成**（提交 `972f34d`，见 §2.3） |
| ~~P-0~~ | ~~升级内置轻舟快照 v0.10.0 → v0.12.0~~（§14） | ✅ **已完成**：快照 `3d6c1a36`、`UPSTREAM_COMMIT` 已修正、六套测试 FAIL 0 |
| ~~P0~~ | ~~§5.1 / §5.2 / §5.5：业务配置 / 结果语义映射 / 降级契约~~ | 🟡 **已落地**：代码就绪、闸门全绿（`ai-check` 5/0 · `ai-e2e` 42/0）。**未满足的两项**：公网真模型端点未联调、U1–U12 单测未写 |
| ~~P1（只读那半）~~ | ~~§5.6：工具调用 + 权限收敛 + 循环上限 + 审计~~ | ✅ **已完成**：denied 路径有单测 + e2e；权限只走 `can()` |
| ~~P1b（L1 那半）~~ | ~~§5.6 的写操作：模型提议 → 客户端确认 → 服务端执行~~ | ✅ **已完成**：`set_my_task_status`；确认令牌（5 分钟 / 一次性 / 绑定 actor）+ TOCTOU 重授权 + 4 个显式错误码，均有单测 |
| **P1c** | 写操作 **L2**（create_task / set_task_due / update_task_status）与 **L3**（删任务、停用成员、移交会长等） | L3 **永久排除**；L2 每个工具接上既有业务核心（同 `taskStatusApply` 那样抽共享函数） |
| **P2** | 流式（SSE）：`postStream` → 服务端 SSE 推给客户端 | 边读边推，且不污染连接池（轻舟注释有提醒） |
| **P3** | ~~关闭明文端口~~ → **保留（已决策）**，仅在公网部署前收口 | 见 §9.3 |

> **P-0 建议排在 P0 之前**：v0.12.0 已提供传输层/归一化/schema/限流/脱敏，
> 先用框架能力可以把 P0 从「自建 4 个模块」压到「只写业务层」，避免白写一遍再删。

---

## 13. 附录：验证证据

| 证据 | 位置 |
|---|---|
| 出站 HTTP/HTTPS 五项能力（1.1.3） | `spike/llm-http/FINDINGS.md` + `evidence/run.log` |
| 出站五项能力**在 1.2.0 下复验** | 本文 §2.2（结果与 1.1.3 逐项一致） |
| 信号量 API 与限流实测（1.2.0） | `spike/semaphore/probe.cj` |
| club-server / 运维台在 1.2.0 下编译 | 本文 §2.2（exit=0，产物字节数已记） |
| 工具链串台与 BOM 两个环境坑 | `spike/llm-http/FINDINGS.md` §4 |

---

## 14. 对照上游轻舟：符合性检查（2026-10-02）

### 14.1 结论

**原内置快照（v0.10.0）不符合本 spec；上游 v0.12.0 已把本 spec 的 P0 绝大部分做进了框架。**
本项目**已于 2026-10-02 完成升级**（见 §14.7），现在内置的就是 v0.12.0 的能力。

### 14.2 上游在 v0.10.0 之后的新增（8 个提交）

| 版本 | 提交 | 内容 |
|---|---|---|
| **v0.11.0** | `4354eba` | **出站增强：HTTPS/TLS 客户端 + 重试退避 + 可注入传输层** |
| **v0.12.0** | `871ff16` | **出站并发控制 + 容错 JSON 提取 + schema 校验 + 日志脱敏** |
| HEAD | `3d6c1a36` | 另含：路由静态分支 404 修复、**参数化查询 `dbquery.cj`(610 行)**、MySQL `NO_BACKSLASH_ESCAPES`、NULL 列崩溃修复 |

新增源码：`src/outbound.cj`(405) · `src/jsonschema.cj`(193) · `src/dbquery.cj`(610)

### 14.3 逐条对照

| 本 spec 要求 | v0.10.0（现内置） | v0.12.0（上游 HEAD） |
|---|---|---|
| C1 出站 TLS 客户端 | ❌ 无（`httpclient.cj` 明写"需要 TLS 请直接用 stdx"） | ✅ `OutboundTlsOptions` + `StdxTransport` |
| C2 必须 `import stdx.net.tls.*` | — | ✅ 已做，且注释写明原因 |
| C3 Windows 上用 `CustomCA` | ❌ | ✅ `caBundlePath` → `CertificateVerifyMode.CustomCA`（Linux 上继续显式给也无害） |
| C4 `TlsClientConfig` 必须 `var` | ❌ | ✅（注释写明） |
| C5 数组不协变 + `as` 返回 Option | ❌ | ✅ `loadCaCertificates` 逐个 `match … as Certificate` 解包 —— **比本 spec 给的写法更严谨** |
| §5.3 可注入传输层 | ❌ | ✅ `HttpTransport` 接口 + `StdxTransport` + **`MockTransport`** |
| §5.2 可重试分类 | ❌ | ✅ `RetryPolicy.shouldRetry`：网络错误 / 429 / 5xx 可重试，其余 4xx 不重试 —— **与本 spec 规则一致** |
| §5.1 重试次数 | ❌ | ✅ `maxAttempts` + 指数退避 + 抖动 + 封顶（**超出本 spec 要求**） |
| §6 P3 并发上限 | ❌ | ✅ `OutboundClient(maxConcurrency:)` 用 `std.sync.Semaphore` + `try/finally` 归还 |
| §5.4 容错 JSON 提取 | ❌ | ✅ `extractJson(text): ?String` + `parseJsonLoose(text): ?JsonValue` |
| §5.4 schema 校验 | ❌ | ✅ `JsonSchema.requireStr/requireIntIn/require/optional` + `validate(obj): ArrayList<String>` |
| S1/S7 日志脱敏 | ❌ | ✅ `redact(text): String` + `REDACT_KEYS` |
| S3 `trustAll` 仅限开发 | ❌ | ✅ 有选项 + 注释「仅限本机开发，禁止进入生产配置」 |
| `.noProxy()` | ✅ 已有 | ✅ |
| 离线单测 | ❌ | ✅ 4 条 `outbound_*` 用例，全程 `MockTransport` 无网络 |

> 换言之：**v0.12.0 把本 spec 里"自己要写的传输层 + 归一化 + schema + 限流 + 脱敏"都做成了框架能力。**

### 14.4 采用 v0.12.0 后，本 spec 的变化

| 位置 | 变化 |
|---|---|
| §3 **C1** | **作废**（框架已有 TLS 客户端）；C2–C5 由框架内部消化，不再是使用方负担 |
| §4 `llm_client.cj` | 从「自建传输层」缩为「业务层配置 + 编排」 |
| §5.3 | 改为**复用 `OutboundClient`**，不再自己 `ClientBuilder` |
| §5.4 | 归一化改用 `extractJson` / `parseJsonLoose`；schema 用 `JsonSchema`，**不必自写括号配平扫描** |
| §6 P3 | 改用框架的 `maxConcurrency` |
| §7 S1/S7 | 复用 `redact()` |

**仍必须由项目自己实现**（框架不该管）：

- §5.1 `LlmOptions`（endpoint / 密钥文件 / CA 路径 / 预算 / `maxRequestBytes` / 启动期校验）
- §5.2 `LlmOutcome` 的业务语义映射（见 14.5-④）
- §5.5 **降级契约**（`SuggestionSource` / `Suggestion<T>`）
- §5.6 **工具调用 + `can()` 权限收敛**（架构叙事主线）
- 提示词与编排

### 14.5 四处差异（需决策，**不建议直接照单全收**）

| # | 差异 | 影响 | 建议 |
|---|---|---|---|
| ① | `OutboundClient.send` 用**阻塞** `semaphore.acquire()`（注释：「全程持有信号量，含退避等待」） | 模型变慢时请求**排队堆积**，每个排队请求仍占着一个入站线程 | ✅ **决策（2026-10-02）：按「锁外做 I/O」处理** —— ①业务层保证智能调用一律发生在 `Store` 锁**之外**（§6.2 P1 不变）；②限流用 `tryAcquire()` + 有限等待（≤500 ms）后**直接降级**，**不使用**无上限阻塞 `acquire()`；③已作为 **E-1** 反馈给上游（原反馈清单 **E-1**；清单已删除） |
| ② | `StdxTransport(timeoutSecs:)` 读/写**共用一个超时** | 本 spec §5.1 要求读/写分开（大模型首字节慢、整体更慢） | 业务层可先接受；或扩展 |
| ③ | `StdxTransport` **没有** `.logger(...)` | 超时仍会往 stdout 打 `WARN … read response timeout`，污染 club-server 日志 | 项目侧无法从外部注入 → **建议给上游提 issue**，或自建薄封装 |
| ④ | `OutboundResponse` 只给 `status` + `networkError: ?String` | **不区分 Tls / Timeout / Network**（本 spec §5.2 的 `LlmOutcome` 要求区分），只能解析 message 字符串（脆弱） | 接受粗分类，或按 message 前缀识别并**记录脆弱性** |

### 14.6 供应链问题：内置快照记录的 commit 不可核验

| 项 | 值 |
|---|---|
| 快照 `UPSTREAM_COMMIT` 记录 | `fbc823ddeb7b07fa81665fbd0d909ce9253daa9f` |
| 该 commit 在上游 | ❌ **不存在**（`git log --all` 无命中） |
| 上游真实 `v0.10.0` | `f0dd9851df2451525e62f5bf79bc0d5c4ca268da` |
| 快照 `src/*.cj` 内容 | ✅ **与上游 v0.10.0 逐字节一致**（SHA-256 全等） |

→ 内容可信，**只是记录的哈希指向了一个不存在的提交**（很可能是上游改写历史前的旧哈希）。
建议把 `UPSTREAM_COMMIT` 改为 `f0dd9851…`，让「可核验」这条真正成立。

### 14.7 升级已执行（2026-10-02）

快照已从自述 v0.10.0 升级到上游 **`3d6c1a36`**，`UPSTREAM_COMMIT` 一并修正为**上游现存的实际 commit**。

**改动清单**

| 项 | 内容 |
|---|---|
| 同步 | 64 个文件（61 个内容变更 + 3 个新增：`src/outbound.cj` / `src/jsonschema.cj` / `src/dbquery.cj`） |
| 一致性 | 63 个受跟踪文件与上游 `3d6c1a36` **逐字节一致**（SHA-256 全等核验） |
| `UPSTREAM_COMMIT` | `fbc823d…`（上游不存在）→ **`3d6c1a3635f9aa4a191cd6aa5ede8bf3a387b753`** |
| `MANIFEST.sha256` | 按索引重新生成，**71 个文件**（原 68） |
| `PROVENANCE.md` | 更新版本/快照时间；新增「供应链核对」与「v0.12.0 带来的能力」两节 |
| 未纳入 | 上游 `examples/` 下 14 个演示文件（按既有约定只保留 `examples/admin.cj`） |

**验证结果（六套全绿，共 1126 条断言 / FAIL 0）**

| 套 | 结果 |
|---|---|
| `build.ps1` 工具链自动选择 | ✅ **自动选中 cjc 1.2.0**（未显式传参） |
| `build.ps1` 内置框架完整性校验 | ✅ 通过（框架 `3d6c1a3`，38 个文件） |
| `club-server` 编译 | ✅ exit=0，**13,473,280 字节** |
| 运维台编译（`-Target admin`） | ✅ exit=0，**12,881,408 字节** |
| 单测 `club-server test` | ✅ **PASS 595 / FAIL 0**（带 DSN 648）|
| 冒烟 `tests/smoke.ps1` | ✅ **PASS 440 / FAIL 0** |
| TLS `tests/tls-check.ps1` | ⚠ **PASS 4 / FAIL 3**（2026-10-04 复测；失败的三条是 SAN 相关 —— `server/certs` 不入库、本机那份是 2026-09-17 的旧件，用**改动前**的二进制复现同样结果 ⇒ **环境性失败，非回归**）。上表"PASS 23 / FAIL 0"是 2026-10-03 当时的状态 |
| 前后端契约 `tests/client-contract-check.ps1` | ✅ **PASS 37 / FAIL 0** |
| 后台 `tests/admin-check.ps1` | ✅ **PASS 38 / FAIL 0** |
| 运维页 `tests/ops-check.ps1` | ✅ **PASS 82 / FAIL 0** |
| OpenSSL DLL | ✅ 3.5.7，与 `EXPECTED.sha256` 一致 |

> **执行说明**：后两套（后台 / 运维页）带一道保护闸门——当 `admin.env` 的 `mysql_db` 是共用默认库
> `club_rbac` 时会**拒绝执行**（因为脚本要 DROP 该库的 RBAC 表）。本次按「用私库名」处理：
> 把 `mysql_db` 改成 `club_rbac_local`（库自动建），**原 `club_rbac` 一字未动**（跑完仍 4 张表）。
> `admin.env` 已备份为 `build\admin\admin.env.bak-before-privatedb`。

### 14.8 副产物：上游按本项目的反馈修复了 8 条

上游 CHANGELOG **直接引用了那份反馈清单的条目号**（清单已随反馈闭环删除）：

| 已修 | A-1 · A-2 · A-3 · A-4 · A-5 · A-7 · B-1 · B-2 |
|---|---|
| 按描述对应 | C-3（`get<String>` → `getOrNull`）· C-6（出站 TLS） |
| 新增反馈 | **E-1…E-4**（阻塞式限流 / 超时不细分 / logger 未暴露 / 失败类别未区分） |

条目对照见本节上表（原清单已删除）。
