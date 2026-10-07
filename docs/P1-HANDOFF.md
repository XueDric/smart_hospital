# P1 交付说明 · 挂号闭环（HTTP 层）

> **日期**：2026-10-07 ｜ **阶段**：P1（挂号闭环）— **首个增量完成**
> **前置**：[ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md)、[P0-HANDOFF.md](P0-HANDOFF.md)

---

## 0. 一句话

P0 的号源数据层现在**暴露成真实 HTTP 接口**了，并且用 **50 个独立进程抢 10 个号**验证了
**不超卖**。过程中并发压测**抓出并修掉了一个 P0 遗留的少卖缺陷**。

---

## 1. 交付了什么

| # | 内容 | 落点 |
| --- | --- | --- |
| 1 | HTTP 应用装配（中间件顺序 + 统一错误出口） | [server/src/http_app.cj](../server/src/http_app.cj) |
| 2 | 统一响应/错误码表（`{ok,data}` / `{ok:false,error}`） | [server/src/http_common.cj](../server/src/http_common.cj) |
| 3 | 三端角色权限矩阵 + `can()` 单一判定 | 同上（`can` / `requireCan`） |
| 4 | 四个 REST 接口 | [server/src/http_app.cj](../server/src/http_app.cj) |
| 5 | `serve` 子命令（端口/bind/开发态鉴权开关） | [server/src/main.cj](../server/src/main.cj) |
| 6 | ★ 多进程并发压测脚本 | [server/tests/stress-booking.ps1](../server/tests/stress-booking.ps1) |

### 接口清单

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| GET | `/health` | 无 | 探活（供压测用） |
| GET | `/api/v1/schedules/:id` | 三端可读 | 查排班（含 `remain_num` / `version`） |
| POST | `/api/v1/appointments` | **仅患者** | 挂号（幂等靠 `client_token`） |
| POST | `/api/v1/appointments/:id/cancel` | 患者退自己的 / 管理员退任意 | 退号并归还号源 |
| POST | `/api/v1/admin/schedules` | **仅管理员** | 建排班（P1 测试用；正式维护界面属 P4） |

**权限矩阵**（`can()` 是唯一判定入口，禁止 handler 手写 if —— 基线铁律）：

| 动作 | 患者 | 医生 | 管理员 |
| --- | --- | --- | --- |
| `view_schedule` | ✅ | ✅ | ✅ |
| `book` | ✅ | ❌ | ❌ |
| `cancel_own` | ✅ | ❌ | ❌ |
| `cancel_any` | ❌ | ❌ | ✅ |
| `manage_schedule` | ❌ | ❌ | ✅ |

> 医生当前**没有写权限**：接诊与写病历属 P4。**不预先发权** ——
> 未实现的动作给权限等于埋一个未测的入口。

---

## 2. ★ 并发压测：这是本增量最有价值的部分

### 为什么必须用独立进程

本仓库（框架 + 应用）**通篇没有 `spawn`**，仓颉 1.2.0 的多线程用法在本项目无先例。
而"并发"的真实形态本来就是**多个客户端同时打同一号源** ——
所以脚本起 N 个 **`curl.exe` 独立进程**，各自建独立 HTTP 连接。

这补上了 [ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md) 明确标注的验证边界：

| AC | 层级 | 证明什么 |
| --- | --- | --- |
| **AC-1**（P0 单测） | 数据库层 | 「过期 version 的 UPDATE 必返回 0 行」= 原子性**根因** |
| **AC-9**（P1 压测） | 端到端 | 「N 个真实并发请求打同一号源，**成功数恰好等于号源数**」 |

### 实测结果（三种工况全绿）

| 工况 | 请求 | 号源 | 成功 | 409 | 余量 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| 供不应求 | 20 | 8 | **8** | 12 | 0 | ✅ 恰好卖光 |
| 高压 | 50 | 10 | **10** | 40 | 0 | ✅ 恰好卖光 |
| 供大于求 | 5 | 20 | **5** | 0 | 15 | ✅ 全成功、余量正确 |

断言含**余量守恒**：`remain_num + 有效挂号单 == total_num`（三种工况都成立）。

---

## 3. ★ 压测抓出的真缺陷（已修）

### 3.1 少卖：乐观锁重试预算不够

**现象**：20 并发抢 8 号，只卖出 **6** 个，`remain_num = 2`（剩两个号没人抢到）。

**性质**：失败方向是**少卖**而不是超卖 —— 安全方向，但**仍然是错的**
（有号却挂不上，患者会以为没号了）。

**根因**：`MAX_BOOKING_RETRY = 2`（共 3 次尝试）。20 个进程同时重读 version、
又同时失败，3 次预算不够。每次重试都要一次读+写往返，冲突窗口没被拉开。

**处置**：
- `MAX_BOOKING_RETRY` 2 → **3**（安全范围上限）；
- 新增 **`HTTP_BOOKING_RETRY = 6`** 作为 HTTP 层的重试预算（`book()` 的 `maxRetry` 已是具名可选参数）。

**修复后**：同样工况 → 恰好 8 个成功、余量 0。

> ⚠ **这不是"调大重试就完事"**：重试是有代价的（每次都是额外往返）。
> 真到重试也扛不住的量级，正确处置是 ADR §3 的**方案 C（悲观锁）或加排队**。
> 本 ADR §8 复审触发条件第 1 条就是为此写的（耗尽率 > 1% → 重估方案 C）。

### 3.2 退号响应自相矛盾

**现象**：退号成功返回 200，但 body 里 `status` 还是 `"booked"`。

**根因**：handler 用了**取消之前**读的那份快照（`appt`）回包。

**处置**：取消后**重读**再回（`Cancelled` 与 `SlotNotRestored` 两条路径都改了）。
自相矛盾的响应比不返回还糟 —— 客户端会以为没退成。

### 3.3 测试脚本自己写错了两处（比不写更糟）

| 坑 | 现象 | 性质 |
| --- | --- | --- |
| `Start-Process -ArgumentList` **拆坏含空格的参数** | `"X-Role: patient"` 到达 curl 变成 `"X-Role:"` → 每个请求都 401，压测显示"0 成功" | **假失败**：看起来像"服务端拒绝并发" |
| 断言不分工况 | "5 并发抢 20 号"（本就该剩 15）被无条件断言"必须卖光"→ 报 3 项失败 | **假失败**：服务端是对的，是断言写错 |

**处置**：header/body 全部走 curl **config 文件**（`-K`），命令行只剩无空格路径；
断言按 `$exhausted = ($Tokens -ge $ScheduleTotal)` **分两种工况**。

> 这两个坑值得单独记：**测试写错会让人去改对的代码。**
> （P0 也踩过同类：变异测试时测试静默崩溃、以及 `exec()` 返回值当自增 id 导致假通过。）

### 3.4 另外两个实测坑

- **curl config 里反斜杠是转义符**：`@C:\Users\...` 被读成 `C:Users...` → 路径必须写正斜杠。
- **PowerShell 的反引号转义在数组拼接里原样写入**：JSON 变成非法串 → `400 Invalid JSON`。
  处置：body 写独立文件，config 用 `data = "@文件"`。

---

## 4. ⚠ 本增量的**临时形态**（必须知道，别当成已完成）

### 4.1 鉴权是开发态的，不是令牌

| 项 | P1 现状 | 基线／目标 |
| --- | --- | --- |
| 身份来源 | `X-Role` / `X-Patient-Id` 请求头 | 不透明令牌 + PBKDF2 三阶段加锁 |
| 开关 | 必须显式 `--dev-auth` | — |
| 审计 | 每请求打 `[DEV-AUTH]` 警告 | 全链路审计 |
| 生产保护 | `--prod` 与 `--dev-auth` 同传 → **拒绝启动** | — |

**为什么用命令行开关而不是环境变量**：本工具链的仓颉 std **没有 `getEnv`/`envVars`**
（框架 `config.cj:17-21` 逐字核对过），基线也因此明说"不支持环境变量配置，只能走命令行"。
用环境变量会**静默永远不生效** —— 那比没有更糟（以为生产被保护了，其实没有）。

### 4.2 默认只绑 127.0.0.1

轻舟 `app.serve(port)` 默认 `bindAddr = "0.0.0.0"`（整个局域网可连），而本阶段是
**明文 HTTP + 开发态身份头**。所以 `serve` 默认**只绑本机**，联调再显式 `--bind 0.0.0.0`。

---

## 5. 怎么跑

```powershell
cd server
.\build.ps1
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital" --port 8091 --dev-auth
```

```powershell
# 另开一个终端
curl.exe -s http://127.0.0.1:8091/health
curl.exe -s -H "X-Role: patient" -H "X-Patient-Id: 1" http://127.0.0.1:8091/api/v1/schedules/1

# 并发压测（会先清表造数据）
.\tests\stress-booking.ps1 -Base http://127.0.0.1:8091 -Tokens 50 -ScheduleTotal 10
```

> ⚠ `serve` 是**阻塞**的；`stress-booking.ps1` 会**清空业务表**后再造数据。

---

## 6. 测试总览

| 套件 | 命令 | 结果 |
| --- | --- | --- |
| schema 自检（无需库） | `hospital-server.exe selftest` | ✅ 29 项 |
| P0 验收（AC-1…AC-8） | `hospital-server.exe accept <dsn>` | ✅ 32 项 |
| **并发压测（AC-9）** | `tests\stress-booking.ps1` | ✅ 三种工况全绿 |
| 手工 HTTP 冒烟 | 见 §5 | ✅ 401/403/400/201/409/200 均符合预期 |

**验收仍以 `build/SOURCE-MANIFEST.sha256` + 测试结果为准**，不要比 exe 哈希
（cjc 产物不逐字节可复现 —— 见 ADR §5.1）。

---

## 7. P1 未完成的部分（下一步）

| # | 待办 | 为什么现在没做 |
| --- | --- | --- |
| 1 | **令牌鉴权体系**（换取/持久化/过期回收，替掉 `--dev-auth`） | 增量太大，先把接口与权限骨架立起来并测通更划算；换令牌时 `principalOf()` 是**唯一改点** |
| 2 | **内存 Store 引入 + AC-4 完整回归**（整库刷盘后断言号源域表逐值不变） | 需要先有科室/医生/病历的内存模型（属后续域） |
| 3 | 患者"我的挂号"列表 | 依赖令牌拿到稳定 patientId |
| 4 | 排班列表（按科室/日期查） | 需先定分页口径 |
| 5 | HTTPS（`serveTls`） | 需证书；⚠ `baseline/server/certs/` 的私钥**已按安全要求剔除**，需重新生成 |

> 换令牌时 `principalOf()` 是唯一改点，这是刻意设计的：
> **权限判定（`can()`）与身份来源（`principalOf()`）解耦**，
> 所以换鉴权方式**不会碰到任何业务逻辑或权限矩阵**。

---

## 8. 参考

- P0 说明：[P0-HANDOFF.md](P0-HANDOFF.md) ｜ 架构决策：[ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md)
- 轻舟 API 事实清单（每条带 file:line）：[../baseline/docs/qingzhou-api-fact-sheet.md](../baseline/docs/qingzhou-api-fact-sheet.md)
- 服务端说明与踩坑：[../server/README.md](../server/README.md)
