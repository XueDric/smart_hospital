# AI 能力运维与排障

> 📁 **AI 运维与排障** ｜ 本文件：`llm-ops-guide.md` ｜ [全部文档目录](README.md)

> 面向**部署、联调、值班**的人。功能契约见 [`api-design.md`](api-design.md) Part 7，
> 客户端对接见 [`llm-frontend-guide.md`](llm-frontend-guide.md)，
> 服务端启动参数见 [`server-guide.md`](server-guide.md)「带 AI 能力启动」。
>
> 最后核对：2026-10-06（对应 `server/src/ai_*.cj` / `h_ai.cj`）。

---

## 0. 一句话心智模型

**AI 是纯增量能力，它挂掉不影响业务。**

- 不配 `--ai-endpoint` → AI 完全不启用，**服务端照常启动**
- 配了但连不上模型 → 接口仍返回 `200`，只是 `data.source = "fallback"`（规则兜底内容）
- **读接口永不 5xx**（这是契约，不是容错）
- **唯一的例外是写操作**：`/ai/agent/confirm` 失败**必须显式报错** —— 用户得知道"没写成"

所以值班时第一件事不是"AI 是不是挂了"，而是**"用户看到的降级是否可接受"**。

---

## 1. 三十秒判断当前状态

### ① 看启动行

服务端启动时会打印一行 `[AI] …`：

| 启动行 | 含义 |
|---|---|
| `[AI] …已启用` | 正常。**只打印主机名**，路径/query 被剥掉，**密钥从不打印** |
| `[AI] 未启用 —— <原因>` | 明确告诉你为什么。见 §2 |

### ② 跑不需要数据库的那套

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File server\tests\ai-check.ps1
```

它**不需要 MySQL**（serve 在连库前就打印 `[AI]` 行），专门验参数与配置解析。
配置写错时它比看日志快。**判据：PASS 5 / FAIL 0**。

### ③ 打一个真实请求看 `source`

```powershell
# ⚠ 必须按 UTF-8 **字节**发 body：PS 5.1 传字符串默认用 ISO-8859-1，中文会变乱码
$json = @{ question = "我有哪些权限？" } | ConvertTo-Json
Invoke-RestMethod -Uri "http://127.0.0.1:8080/api/v1/ai/ask" -Method Post `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($json))
```

> **`source=model` 与 `source=fallback` **都是 HTTP 200**。**
> 别拿状态码判断 AI 是否可用 —— 永远看 `data.source`。

---

## 2. `[AI] 未启用` 的原因清单

按启动行给的原因对号入座（这些都由 `aiValidate` 产出，**不会让服务起不来**）：

| 原因 | 处置 |
|---|---|
| 没给 `--ai-endpoint` | 这是**正常状态**，不是故障。要用 AI 就补上 |
| 端点不是 HTTPS | 默认强制 HTTPS。明文要显式 `--ai-insecure-trust-all 1`（**仅本机**） |
| 缺 `--ai-model` | 补上，如 `deepseek-chat` |
| 缺 `--ai-key-file` | 补上（**只走文件**，不接受命令行直传） |
| 密钥文件读不到 / 为空 | 查路径与权限。**密钥文件不要放仓库里** |
| **CA bundle 不存在** | 见下面的坑 ① |
| `--ai-timeout` 不在 `1..300` | 越界会被拒。`0` = 无限等待，长度溢出风险 |
| `--ai-max-concurrent` 不在 `1..64` | 它直达 `Semaphore` 计数 |
| `--ai-max-tokens` 不在 `64..8192` | **过小会截断输出、进而静默降级** |

### 坑 ①：CA 路径**不能含空格**

项目的命令行**按空格切分参数**。`--ai-ca "D:\Program Files\…\ca-bundle.crt"`
会被切成 `D:\Program`，于是启动行报「CA bundle 不存在：D:\Program」。

```powershell
# 先复制到无空格路径再用
Copy-Item 'D:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt' "$env:TEMP\ai-ca.crt" -Force
```

### 坑 ②：`Default` 在 **Windows** 上必然失败，在 **Linux** 上可用

| 平台 | `CertificateVerifyMode.Default` | 要 `--ai-ca` 吗 |
|---|---|---|
| **Windows** | ❌ 必然 `unknown CA(134)`（spike R5 实测） | **必须给** |
| **Linux** | ✅ 会读系统信任库（`/etc/ssl/certs`） | **本服务仍要求给**（见下） |

2026-10-06 在 **WSL Ubuntu 26.04 + cjc 1.2.0** 实测：`Default` 打 `api.deepseek.com` / `baidu` /
`github` / `bing` 四个公网站点**全部握手通过**（`trustall` 与 `customca` 同样通）。

> ⚠ **但 `aiValidate` 一律要求 `--ai-ca`**（为了在 Windows 上早失败并说清原因），
> 所以 **Linux 上也要给** —— 内容直接用系统那份即可：
> `--ai-ca /etc/ssl/certs/ca-certificates.crt`。
>
> 📌 **勘误**：本文一度写成「与 OS 无关、两个平台都要」，是**未实测的过度推理**，已被上面的实测推翻。

所以：**联调/生产给 `--ai-ca`**；纯本机图省事才用 `--ai-insecure-trust-all 1`，
**绝对不要带进部署包**。

---

## 3. 全部返回 `fallback` 怎么查

`fallback` 意味着**请求没成功到达模型**或**模型输出不可用**。按出站链路自外向内查：

```
DNS/网络 → 代理 → TLS(CA) → 鉴权(401/403) → 限流(429) → 超时 → 响应体大小 → schema 校验
```

| 症状 | 可能原因 | 处置 |
|---|---|---|
| 全部 `fallback`，且很快返回 | 端点写错 / DNS 不通 | 端点要写**完整 URL**（带 `/v1/chat/completions`），只写 base 会 404 |
| **不同问题返回逐字节相同的答案** | **AI 压根没启用**（`ai == None`） | 见下面的「典型误判」 |
| 全部 `fallback`，握手类错误 | CA 没给 / 路径含空格 | 见 §2 坑 ①② |
| 全部 `fallback`，`401/403` | 密钥无效 / 过期 / 余额不足 | 换密钥文件后**重启服务**（密钥只在启动时读一次） |
| `429` 但那是**上游**的 429 | 供应商限流 | 看 `data.note`；本项目自己的限流是 HTTP 429 + `AI_RATE_LIMITED`（见 §4） |
| 超时 | `--ai-timeout` 太小（默认 30） | 调大，上限 300 |
| 响应被拒 | 单次响应超 **256 KiB**（`AI_MAX_RESPONSE_BYTES`） | 调小 `--ai-max-tokens`，或换更简洁的提示词 |
| 有输出但落兜底 | 输出过不了 schema 校验 | **这是有意的**：绝不把没校验的内容当业务值。看是不是提示词被改了 |
| 偶发 | 网络抖动 | 有重试（见 §5），偶发单次可忽略 |

#### 典型误判：`/ai/ask` 对不同问题返回相同答案

**这不是 bug** —— 它是「AI 未启用」的标准表现，2026-10-06 有人据此判断"这条路径有问题"，
实际原因是起服务时没配 `--ai-endpoint`。链条是这样的：

1. `ai == None` → 走 `case None` 分支，**根本不发起出站**（所以 stub 收不到任何请求）
2. 兜底答案是 `aiPermFallbackAnswer(perms)` —— 它**只接收权限串、根本不看 question**，
   所以两个不同问题必然得到**逐字节相同**的答案
3. 响应里其实写了原因：`data.source = "fallback"`、`data.note = "智能问答暂不可用（AI 未配置）"`

**判据永远是 `data.source`，不是 HTTP 状态码，也不是答案文本**。
（2026-10-06 起兜底文案会自述「模型暂不可用…这不是对你所提问题的回答」，
就是为了让"只看文本"的人也能立刻发现。）

> **本机代理提醒**：若你的网络需要代理，`HTTP_PROXY`/`HTTPS_PROXY` 要**给服务端进程**设。
> 系统代理（WinINET）不会被自动读取 —— 这是本项目与 git 都踩过的同一类坑。

---

## 4. 节流（429 `AI_RATE_LIMITED`）

**成员级滑动窗口**：`AI_RATE_LIMIT = 20` 次 / `AI_RATE_WINDOW_MS = 60 秒`。

- 是**滑动**窗口，不是固定窗口（固定窗口会让窗口边界处的实际速率翻倍）
- 被拒的请求**不会打到付费 API** —— 这是节流存在的意义
- **不消耗模型出站的结果会被退额**：例如本地就拦下的非法输入、配置未启用等
  （否则用户会被"自己没花的钱"限流）
- **`/ai/agent/confirm` 不吃额度**：它不调模型、没有出站请求

**处置**：等窗口滑过去即可，客户端应把它当"稍后重试"而不是错误。
若正常业务就被打到 429，说明 `--ai-max-concurrent` 之外的**人均调用量**需要重新设计，
不要靠调大限制掩盖。

---

## 5. 重试与超时的口径

- 出站重试策略：`RetryPolicy(1, 300, 2000)` —— 1 次重试，基础 300 ms，上限 2000 ms
- 外层最多 2 轮，轮间 **300 ms** 退避
- **只有** `timeout` / `network` / `rate_limited` / `server_error` 会重试
- **`too_large` 与 `truncated` 不重试**（重试也不会变好，只会多花钱）
- 结果被截断（`finish_reason = length`）→ 记为 `truncated`，**不重试**，直接走兜底

> **锁纪律（改代码前必读）**：**绝不在持 `s.lock` 时做出站调用**。
> 实测过一次：持锁调模型让并发退化到串行（8089 ms vs 2034 ms）。
> 三段式：认证（自锁）→ 锁内取数 → **锁外**调模型。

---

## 6. 审计怎么看

`audit.log` 里与 AI 相关的行：

| 行 | 何时写 |
|---|---|
| `ai_tool` | agent 循环里跑了一个**只读**工具 |
| `ai_tool_propose` | 产出了一个**写操作提议**（字段：`tool=` `proposed=` `round=`）|
| `ai_tool_confirm` | 用户确认并执行了写操作（含 `resource=<id>`） |

**令牌只记前 8 位**（`ap_7f3c9e12`）。完整令牌**从不进日志** ——
否则能读日志的人就可以拿它去执行写操作。

**排查写操作时**，用这三行连起来看：提议过没有 → 用户确认没有 → 执行结果。
三者缺一，就能定位是"模型没提"、"用户没点"还是"执行被业务规则拒了"。

---

## 7. 费用控制

| 手段 | 默认 | 说明 |
|---|---|---|
| 成员级节流 | 20 次 / 60 秒 | §4 |
| 请求体上限 | `AiOptions.maxRequestBytes` | 超了直接本地拒，不打到付费 API |
| 响应体上限 | 256 KiB | 超了记为 `too_large`，不重试 |
| 单次 token 上限 | `--ai-max-tokens` 2048 | 也是费用闸门 |
| 并发上限 | `--ai-max-concurrent` 4 | 防一次高峰打出一串调用 |
| agent 轮数 | ≤ 4 轮 | 每轮一次调用，响应里 `calls` 字段**对客户端可见** |
| 风控调用 | 单次列表刷新 ≤ 5 个申请人 | 且**有内存缓存**，每个申请人只花一次 |
| confirm | **不调模型** | 不吃额度 |

**响应里的 `calls` 字段是有意的费用可见性**：客户端能显示"这次问询花了几次调用"。

---

### 7.1 单实例假设与已知边界（**别再报成新 bug**）

> 有人报过「AI 限流只对单进程有效，多实例后每实例都能给同一用户重新分配额度」。
> **前提不成立** —— 但结论里有一条**真缺口**值得记下来。逐条说清。

#### ① 不是 AI 模块的缺陷，而是**整个架构**的既定边界

AI 的限流计数、风控缓存确实是**进程内**的，但**内存态的不止这些**：
整个 `Store`（部门/成员/任务/课题/令牌/幂等）都常驻**每个进程各一份**，
没有跨实例失效通知。所以两个 `club-server` 写同一个库，**先坏的是业务数据**
（同一行的并发更新会互相覆盖），远早于限流被放大。

这一点项目**早就写明并接受**了：

| 位置 | 原话 |
|---|---|
| `docs/mysql-backend.md` §多实例 | 「**多实例仍不安全**：内存 Store 每进程一份、没有失效通知 —— 两个 club-server 写同一个库…」 |
| `docs/club-server-mysql-assessment.md` | 「§七 路线 B 的已知代价：拿不到水平扩展 ⚠ **仍然成立**」 |
| `docs/local-deploy.md` 未覆盖项 | 「**多实例共写同一个库**（路线 B 明确不支持）」 |
| `docs/cangjie-cup-2026-evaluation.md` §七 答辩预案 | 「**风险题**：多实例共写同一库不支持（路线 B 已知代价，README 已如实记录）—— 如实说明比掩饰好」 |

**所以正确的处置是：如实说明边界，而不是给限流器单独搬 Redis。**

> ⚠ **只把限流搬进 Redis 是"半个修复"，比不修更危险** —— 它会让系统**看起来**能多实例，
> 而业务数据的丢更新照旧。**要先解决的是 Store 的失效通知**（订阅/版本号/短 TTL 重载），
> 那是另一个量级的改造。

#### ② 但内存态**确实**有该区分的两类

不是所有进程内状态都一样，判据是「**丢了会怎样**」：

| 状态 | 类型 | 重启丢失的后果 | 多实例的后果 |
|---|---|---|---|
| `g_aiRate`（成员 AI 配额） | 成本闸门 | 额度重置（**可接受**，见下） | 额度 ×N |
| `g_riskCache`（风控分档缓存） | **纯缓存** | 重算一次（花一次模型调用） | 重算 ×N，且**各实例角标可能不一致** |
| `s.login_fail` / `s.reg_fail` | 防爆破 | 计数清零（**可接受**） | 各自计数 |
| **提议令牌 / 幂等记录** | **正确性** | —— | —— |

**最后一行要划重点**：**提议令牌与幂等记录从来就不是内存态** ——
它们存在 MySQL 的 `idem` 表里（`payload` / `used_at` 两列，见 `schema_version` 迁移 v1）。
**这两项本来就是跨进程共享的**，不需要"迁移到 Redis"。

`store.cj:224-229` 也给了"限流为什么放内存"的**成文理由**：

> 失败是高频路径，每失败一次就整库原子写一次，等于给攻击者一个
> "发一个 401 换 18 MB 磁盘写"的放大杠杆。重启后计数清零可以接受 ——
> **攻击者没有让服务重启的手段**。

这条推理对 **AI 配额**同样成立：它的目的是**防单个成员把费用烧穿**，而重启不在用户手里。

#### ③ 真缺口：**没有全局 / 按日的费用上限**

单成员 20 次/分钟是**人均**封顶，但 **N 个成员 × 20/分钟没有总量天花板**，
也没有"按社团 / 按模型 / 按日"的预算。**这是真的缺**，而且正如报告所说 ——
**多人使用时最先失控的可能是费用，不是 CPU**。

现有能挡的只有这些（都在 `AiOptions` / 单个请求内，是**逐请求**的）：

| 闸门 | 默认 | 作用域 |
|---|---|---|
| `--ai-max-tokens` | 2048 | 单次补全 |
| `maxRequestBytes` | — | 单次请求体 |
| `AI_MAX_RESPONSE_BYTES` | 256 KiB | 单次响应 |
| `--ai-max-concurrent` | 4 | 同时在途 |
| `AI_AGENT_MAX_ROUNDS` / `AI_AGENT_BUDGET_MS` | 4 / 20 s | 单次 agent 请求 |
| `AI_RATE_LIMIT` / `AI_RATE_WINDOW_MS` | 20 / 60 s | **单成员** |
| `AI_RISK_MAX_CALLS` | 5 | 单次列表刷新 |

**缺的是"聚合维度"的闸门**：按社团/按日、按模型。加它需要一个**持久的日计数器**
（重启不该清零 —— 这是与上面"限流放内存"**不同**的判断，因为日预算跨天且要防"重启绕过"）。

> **要加的话，落点建议**：复用 `idem` 表那种"落库的短记录"模式（或 `meta` 的计数器字段），
> 键 = `<社团>:<模型>:<YYYY-MM-DD>`，每次出站前累加、超限则 `429 + AI_RATE_LIMITED`。
> **注意**：那样每次 AI 调用会多一次 DB 往返 —— AI 调用本身是秒级 + 花钱，这点开销可忽略。
---

## 8. 上线前检查清单

- [ ] `--ai-endpoint` 是 **HTTPS** 且是**完整 URL**
- [ ] `--ai-ca` 指向 CA bundle，**路径无空格**
- [ ] 密钥文件在**仓库外**，权限收紧，**不在任何提交里**（`git log -S 'sk-'` 扫一遍）
- [ ] **没有** `--ai-insecure-trust-all`
- [ ] `--ai-timeout` / `--ai-max-tokens` / `--ai-max-concurrent` 在允许区间内
- [ ] 启动行是 `[AI] …已启用`，且**不含密钥**
- [ ] `ai-check.ps1` 绿（PASS 5 / 0）
- [ ] `ai-e2e.ps1` 绿（PASS 71 / 0）
- [ ] 打一个真实请求，`source=model`（用 `tests\ai-real.ps1`，**会花钱**）
- [ ] 断网/拔密钥演练一次：AI 接口仍 **200 + fallback**，业务不受影响

---

## 8.5 附：怎么在 Linux/WSL 上自己验一遍出站

上表那两行平台结论是**实测**出来的，可复现。整条链路（WSL Ubuntu 26.04 + cjc 1.2.0 实测）：

```bash
# ① 编译出站探针（单文件；不需要 MySQL、不需要服务端）
CJ=/opt/cangjie-sdk-1.2.0/bin/cjc
DYN=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx
REPO=/mnt/e/harmonyOS/cangjie_web

#   ⚠ 用**动态** stdx：静态库之间是循环依赖，-l: 列表列两遍也解不开（实测）
#   ⚠ 必须剔除 fuzz / unittest：它们要 sanitizer 钩子与 std.unittest，会链接失败
LIBS=$(cd $DYN && ls libstdx*.so | grep -v -E "fuzz|unittest" | sed "s|^|-l:|" | tr "\n" " ")

$CJ $REPO/spike/llm-http/spike_main.cj --import-path $DYN -L $DYN -Woff unused $LIBS -o /tmp/spike

# ② 跑（LD_LIBRARY_PATH 三个目录缺一不可）
export LD_LIBRARY_PATH="$DYN:/opt/cangjie-sdk-1.2.0/runtime/lib/linux_x86_64_cjnative:/opt/cangjie-sdk-1.2.0/lib/linux_x86_64_cjnative"
/tmp/spike http://127.0.0.1:1 https://api.deepseek.com ""
#   ↑ base 指向不通的端口即可 —— R1..R4 会失败，不影响 R5 的结论
```

关心的输出是 R5 那三行：

```
[R5/default]  status=401  => HTTPS 通     ← Linux 上 Default 可用
[R5/trustall] status=401  => HTTPS 通
[R5/customca] status=401  => HTTPS 通     ← 给了 CA 也能用
```

> `api.deepseek.com` 对无鉴权请求回 **401**，正好用来判「握手通没通」—— **401 就是通**，
> 不需要真密钥。换 `https://www.baidu.com` 会回 200，同样算通。
>
> ⚠ **别只看「能连上」**：`Test-NetConnection host 443` 这类 TCP 探测在 TLS 被拦时**照样返回 True**
> （本机实测踩到过），必须看**真的完成了一次 HTTP 往返**。

## 9. 不要做的事

1. **不要把密钥放进仓库、命令行参数或日志。** 只用 `--ai-key-file`，文件放仓库外。
2. **不要用 HTTP 状态码判断 AI 是否可用。** 看 `data.source`。
3. **不要让模型输出直接成为写库值。** 所有写操作走「提议 → 用户确认 → 执行」三段式；
   风控分档**只影响呈现与排序，不做自动通过**。
4. **不要在持 `s.lock` 时调模型。** 见 §5。
5. **不要在写操作上沿用读接口的降级语义。** 写失败**必须显式报错**。
6. **不要把 `--ai-insecure-trust-all 1` 带进部署。**
