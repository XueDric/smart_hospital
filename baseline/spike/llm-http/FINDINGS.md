# 仓颉出站 HTTP/HTTPS 能力 spike · 结论

> 目的：在写「任务全生命周期智能体」之前，先把「仓颉服务端能不能稳定调大模型」变成确定事实，
> 避免 22 天计划建在假设上。
>
> 环境：cjc **1.1.3** (cjnative, x86_64-w64-mingw32) + stdx **1.1.3.1** + OpenSSL 3
> 证据：`evidence/run.log`（完整输出）· 复现命令见文末
> 结论时间：2026-10-01

---

## 0. 一句话结论

**技术上可行，但不是"直接用就行"——有三条硬约束必须先落到设计里，否则会同时踩到
"调不通 HTTPS""解析不了模型输出""把整个服务拖成串行"三个坑。**

---

## 1. 五项风险结论一览

| # | 风险 | 结论 | 关键证据 |
|---|---|---|---|
| R1 | 明文 HTTP 出站调用 | ✅ **可用** | `/echo` 回显 method/Authorization/content-type/body 全对 |
| R2 | 超时能否真正中断 | ✅ **可用** | 服务端睡 5s，客户端 2s 断开，实测 **2032ms** 返回 |
| R3 | 模型输出的 JSON 解析 | ⚠ **必须加归一化层** | 代码块包裹、前后带自然语言**一律解析失败** |
| R4 | 外部慢调用与锁的关系 | ❌ **锁内做 I/O 会串行化** | 4 线程 × 2s：锁内 **8088ms**，锁外 **2034ms** |
| R5 | 公网 HTTPS（大模型 API 必须） | ⚠ **可行但必须自备 CA** | `Default` 失败；`TrustAll` / `CustomCA` 成功 |

---

## 2. 逐条展开

### R1 明文 HTTP —— 可用

`ClientBuilder() → HttpRequestBuilder().method/url/header/body.build() → client.send(req) → resp.status / resp.body`
这一套与轻舟 `httpclient.cj` 完全一致，业务侧可以照抄。

### R2 超时 —— 可用，且失败形态是"可分类的"

- 到点**真的断开**（2032ms），不会挂死。
- 超时**不抛穿业务**：`client.send()` 抛异常后由我们接住，形态是
  `status=0` + `reason="Client1.1 read response timeout and the connection is closed."`
  → 正好能接进"降级/重试"的分支判断（对应轻舟 `HttpResult.isNetworkError()` 那套语义）。
- ⚠ 副作用：stdx 会往 stdout 打一行 `WARN ... read response timeout`。
  生产上要用 `ClientBuilder().logger(...)` 把级别压下去（服务端 `app.cj` 已有先例）。

### R3 JSON 解析 —— 这是最容易踩的坑

`stdx.encoding.json.JsonValue.fromStr` 是**严格标准 JSON 解析器**：

| 输入形态 | 结果 |
|---|---|
| `{"ok":true,...}` | ✅ JsonObject |
| `{"ok": true, "data": {`（截断） | ❌ `Unexpected character: '{'` |
| 空串 | ❌ `Json String is empty!` |
| ` ```json\n{...}\n``` `（代码块包裹） | ❌ `Unexpected character: '\`'` |
| `好的，建议如下：{...} 以上。`（前后带话） | ❌ `Unexpected character: '好'` |

**而模型输出恰恰最常是后两种形态。**

→ 结论：必须自建一层 **输出归一化 + 校验**，顺序是：
1. 去掉 ``` 代码块围栏
2. 抽取**第一个配平的 `{...}`**（注意字符串里的花括号与转义）
3. 再交给 `JsonValue.fromStr`
4. 用 schema 校验字段与类型；不合法就重试一次，再不行**退回规则结果**，绝不把幻觉写进库

这一层不是"锦上添花"，是**没有它功能就不可用**。

### R4 并发与锁 —— 已复现，必须写进架构纪律

```
坏模式（拿着锁做 2s 外部调用）：4 线程总耗时 8088ms   ← 完全串行
好模式（I/O 在锁外，只锁状态更新）：   总耗时 2034ms   ← 真并行
```

差值 **6054ms**。

这与本项目 PBKDF2 那次修复是同一个病（当时把 PBKDF2 移出全局锁换来
"4 并发登录 1574 → 867ms"）。大模型调用**比 PBKDF2 更慢、更不可控**（秒级），
所以这条更要命：一个用户点"生成通知"就会让整个社团的接口全部卡住。

→ 纪律：**所有对外智能调用一律在锁外**；锁只保护内存状态的那几行赋值。
   并且必须给智能调用单独的超时与并发上限（否则模型慢时会把线程吃光）。

### R5 公网 HTTPS —— 可行，但 Windows 上默认没有信任库

对 `https://api.deepseek.com/v1/models`（真实大模型 API 域名）实测：

| 校验模式 | 结果 |
|---|---|
| `CertificateVerifyMode.Default` | ❌ `TLS handshake failed: certificate verify failed (134), TLS alert unknown CA(F)`（125ms） |
| `CertificateVerifyMode.TrustAll` | ✅ status=401（447ms）—— 打通，401 正是"没带 Key"的预期响应 |
| `CertificateVerifyMode.CustomCA(ca-bundle.crt)` | ✅ **status=401（233ms）—— 带完整校验，推荐** |

**`Default` 失败的原因**：OpenSSL 在 Windows 上**不使用系统证书库**，而 Cangjie 的
默认 TLS kit 没有内置根证书 → 没有 CA 可校验。

**生产做法**：随部署包带一份 CA bundle，用 `CustomCA` 显式加载：

```cangjie
import stdx.crypto.common.*      // Certificate 接口
import stdx.crypto.x509.*        // X509Certificate
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*     // ← 少了这个会报 "Global TLS kit is not set"
import std.fs.*                  // File.readFrom

let pem = String.fromUtf8(File.readFrom(caBundlePath))
let acc = ArrayList<Certificate>()
for (c in X509Certificate.decodeFromPem(pem)) {
    acc.add(c)
}
var cfg = TlsClientConfig()                    // 注意必须是 var
cfg.verifyMode = CertificateVerifyMode.CustomCA(acc.toArray())
let client = ClientBuilder()
    .noProxy()
    .readTimeout(Duration.second * 30)
    .writeTimeout(Duration.second * 30)
    .tlsConfig(cfg)
    .build()
```

⚠ 三个 API 细节（都会编译报错，记下来省时间）：
- `TlsClientConfig` 必须先 `var` 再赋字段（`let` 会报 *cannot assign to immutable value*）
- `CustomCA` 收的是 **`Array<Certificate>`（接口）**，不是路径字符串；
  且数组**不协变**，`Array<X509Certificate>` 得逐个装进 `ArrayList<Certificate>`
- 证书加载用 `X509Certificate.decodeFromPem(pem 文本)` + `File.readFrom(path)`
  （与 `server/src/main.cj:977` 读 cert.pem 同一套路）
- 另外：**exe 旁边必须有 `libcrypto-3-x64.dll` + `libssl-3-x64.dll`**，缺了编译期无警告，
  运行时才报 `Can not load openssl library or function CRYPTO_get_ex_new_index`

---

## 3. 一个顺带发现（对公网部署有直接影响）

轻舟 `httpclient.cj` **没有 TLS 入口**（其文件头就写明"需要 TLS 请直接用 `stdx.net.http.Client`"），
这一点他们自己在 `docs/qingzhou-upstream-issues.md` 的 **C-6** 里记过
（⚠ 该清单已于 2026-10-04 **随反馈闭环删除** —— 上游 v0.12.0 的 CHANGELOG 直接引用了它的条目号，
确认修复了其中 8 条。要看条目原文：
`git log --diff-filter=D -- docs/qingzhou-upstream-issues.md`）。
现在的绕法是**给 club-server 额外开一个明文端口**专供运维台调用（靠防火墙兜）。

而在"只交客户端 + 公网部署"的方案里，这个明文端口是要暴露在公网的。
本 spike 证明了**自己用 `stdx.net.http` + `CustomCA` 就能走 HTTPS**，
所以运维台那条链路**可以改回 HTTPS，明文端口可以关掉**——建议排进 22 天计划。

---

## 4. 本次踩到的两个环境坑（都不是 spike 代码的问题）

### 坑 1：`LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func`

- **现象**：编译中途 `opt.exe` 崩溃（0xC000001D），堆栈里是
  `C:\Users\ASUS\.cjenv\sdks\1.0.5\...\opt.exe` —— 前端 cjc 1.1.3 配了后端 LLVM 1.0.5。
- **诱因**：本机 `CANGJIE_HOME` 被 cjenv 改写成 1.0.5 SDK；cjc 据此去找 `opt.exe`，
  **PATH 前置没用**。
- **处置**：编译前 `$env:CANGJIE_HOME = <真实 SDK 目录>`（同 `server/build.ps1` 的 225-227 行）。
- **教训**：这个报错看着像"编译器 bug"或"stdx 版本不匹配"，实际是工具链串台，先查 CANGJIE_HOME。

### 坑 2：PowerShell 5.1 把无 BOM 的 UTF-8 脚本按 GBK 解码

- **现象**：脚本里一行 `$env:CANGJIE_HOME = $CangjieHome` **凭空没执行**，
  后面的变量读出来还是旧值，而脚本本身语法完全正确。
- **根因**：`.ps1` 存成 **UTF-8 无 BOM**，PS 5.1 按本地代码页（GBK）解码，
  中文注释的乱码字节破坏了注释边界，把下一行代码一起吞掉。
- **处置**：**所有含中文的 `.ps1` 必须存成 UTF-8 with BOM**。
- **证据**：仓库现有 **15 个 `.ps1` 全部带 BOM**（团队早就知道这个坑），
  只有本次新增的 `spike/llm-http/build.ps1` 漏了 → 已补。

---

## 5. 复现

```powershell
cd spike\llm-http

# 1) 编译（会顺带把 4 个 DLL 拷到 build\）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 2) 起桩服务（模拟大模型 API 的各种返回形态）
node stub.mjs 18080

# 3) 跑（第三个参数是 CA bundle；Windows 上可借 Git 自带的）
.\build\spike.exe http://127.0.0.1:18080 `
    https://api.deepseek.com/v1/models `
    "D:\Program Files\Git\usr\ssl\certs\ca-bundle.crt"
```

| 文件 | 作用 |
|---|---|
| `spike_main.cj` | 五项验证的仓颉源码 |
| `stub.mjs` | 本地桩服务（ok / badjson / fenced / prose / slow / e500 / e401 / echo / big） |
| `build.ps1` | 独立构建链（**带 BOM**，含 CANGJIE_HOME 修正） |
| `evidence/run.log` | 本次完整输出存档 |

`spike.exe` sha256：`EB3AE9DD5A8394AED52E7A1936E289EC59D5C839FBC397D9E2491ABDA56BA54B`

---

## 6. 本 spike 未覆盖（下一步）

1. **流式（SSE）**：轻舟有 `postStream`，但大模型流式还要验"边读边推给客户端"的链路
   （`HttpStream.read` → 服务端 SSE 响应）。
2. **tool calling**：让模型调你们的 40 个接口。schemas 定义、循环终止条件、
   以及**所有调用必须仍然经过 `can()`**（这是能同时拿"架构分"和"智能分"的设计点）。
3. **CA bundle 随包分发**：从 Git 借 CA 只是本机权宜，部署包要自带一份并做版本记录。
4. **真实模型 Key**：本次用 401 证明链路通；带 Key 的端到端与限流/计费还要另测。

---

## 7. 附：cjc 1.2.0 复验（2026-10-01，工具链升级决定后）

服务端决定把基线升到 **cjc 1.2.0**（上游轻舟 v0.10.0 的发布口径），因此五项能力**在 1.2.0 下重跑**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 `
    -CangjieHome "C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie"
```

| # | 1.1.3 | 1.2.0 | 结论 |
|---|---|---|---|
| R1 明文 HTTP | PASS | PASS（200，头/体一致） | 无变化 |
| R2 超时中断 | 2032 ms | **2029 ms** | 无变化 |
| R3 JSON 严格性 | 围栏/自然语言均失败 | **同样均失败** | 无变化 → 归一化层照样必需 |
| R4 锁内 I/O | 8088 / 2034 ms | **8104 / 2040 ms** | 无变化 |
| R5 `CustomCA` 打通 | 233 ms | **264 ms** | 无变化 |
| R5 `Default` | 失败（unknown CA） | **同样失败** | 无变化 → C3 约束在 1.2.0 下依然成立 |

**附带验证**

| 项 | 结果 |
|---|---|
| stdx 1.1.3.1 配 cjc 1.2.0 | ✅ 无 LLVM 串台、无 API 破坏 |
| `club-server` 全量编译（35 框架 + 25 应用文件） | ✅ exit=0，13,317,120 字节 |
| 运维台全量编译（37 框架含 `store.cj` + 8 文件） | ✅ exit=0，12,721,664 字节 |

**新踩到的两个坑（已写入 `docs/llm-client-spec.md` §11）**

1. **运行时 DLL 必须与编译器同代**：1.2.0 的 `libcangjie-runtime.dll` 是 1,297,408 字节，
   1.1.3 的是 1,276,416 字节。本 spike 的 `build.ps1` 原先从 `server/build` 借 DLL（1.1.3 代），
   用 1.2.0 编译后会错配 → 已改为**运行时取自 `<SDK>\runtime\lib\...`**，OpenSSL 仍外借。
2. **`build.ps1:94` 硬编码 `-match '1\.1\.'`**：`cjenv use 1.2.0 --persist` 之后，
   该函数仍会挑中 `D:\Cangjie`（1.1.3）并覆写 `CANGJIE_HOME` → **升级静默不生效、零警告**。
   这是升级工作的**唯一功能性阻塞点**。

