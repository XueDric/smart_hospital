# ADR-0001 · 号源与挂号采用「脱离内存 Store 的独立 MySQL 权威路径」

| 项 | 值 |
| --- | --- |
| **状态** | Accepted（已接受） |
| **日期** | 2026-10-07（创建）｜ 2026-10-07（复查修订 rev.2） |
| **阶段** | P0 —— 架构决策落定 |
| **决策者** | 项目组（依据 `smart-hospital-project-brief.md` §5.1） |
| **影响面** | `server/src/` 数据访问层；新增 `schedule` / `appointment` / `booking_idem` |
| **关联** | `smart-hospital-project-brief.md` §4 复用映射、§5.1、§7；基线 `mysql_store.cj:30-37` |

### 修订记录

| 版本 | 日期 | 改了什么 | 触发原因 |
| --- | --- | --- | --- |
| rev.1 | 2026-10-07 | 初版 | P0 立项 |
| **rev.2** | 2026-10-07 | ①§4.3 口径矛盾修订（拆「业务状态」/「幂等基础设施」两层）；②§4.3.2 新增并修掉与基线 `idem` 撞名（→ `booking_idem`）；③§5 补 AC-7/AC-8，AC-4 扩大到全表比对；④§5.1 新增「源码哈希而非产物哈希」；⑤§7 修正验收测试落点笔误（`server/tests/` → `server/src/acceptance.cj`）；⑥§8 补第 5 条复审触发条件 | 用户复查提出的 5 项发现（口径打架、撞名、`cancel()` 边界缺陷、文档笔误、产物不可复现） |

---

## 1. 背景（Context）

### 1.1 复用基线的持久化范式

我们从 `cangjie_web` 复用的服务端，持久化范式是：

> **全量载入内存 + 全局锁 + 每次提交整体替换各表**
> —— 证据：`baseline/server/src/mysql_store.cj:30-37`（"一次提交要整体替换 7 张表"）、
> `baseline/docs/...` 与 `baseline/README.md` 未决 #12 / S-14。

该范式对**社团管理**是合适的：数据量小（千人档）、读多写少、单实例、业务不要求毫秒级扣减。

### 1.2 挂号场景提出的新要求

参考系统（`smart-hospital-project-brief.md` §2.3）给出两条必须照搬的机制：

1. **防超卖**：排班表 `version` 乐观锁 + 扣减带 `remain_num > 0` 条件；
2. **顺延不串号**：挂号单保存 `visit_date` **就诊日快照**。

第 2 条与持久化路径无关，照做即可。**第 1 条是本次决策的全部压力来源。**

### 1.3 为什么不能把排班表塞进 `PersistedState`

若把 `schedule` 放进现有内存 Store，会**同时**继承三个代价：

| # | 代价 | 依据 |
| --- | --- | --- |
| 1 | **整表替换写放大** —— 每次挂号重写整个排班/订单表 | `mysql_store.cj:30-37` |
| 2 | **`s.lock` 跨一次网络事务持有** —— 全部挂号串行化，且与整库刷盘争锁 | 基线 S-14：「这把锁是**跨一次网络事务**持有的」 |
| 3 | **并发扣减被完全串行化** —— 乐观锁的意义被抹掉 | 同上 |

并且基线 README 未决 #12 已明确记载：

> **「跨实例共享同一份数据仍然不成立：内存 Store 是每进程一份、没有失效通知」**

**结论**：号源是**唯一**不能走内存 Store 的域。

---

## 2. 决策（Decision）

### 2.1 一句话

> **号源 / 挂号单独成域，不进 `PersistedState`，由 MySQL 权威；
> 扣减用参数化原子 `UPDATE` + `version` 乐观锁 + `remain_num > 0` 条件，
> 与挂号单 INSERT 同处一个 `withTransaction`。**

### 2.2 具体做法

```cangjie
// 复刻参考系统的 version 乐观锁 + remain_num > 0 条件，
// 并利用 DbBackend.exec(sql, params) 的**受影响行数**返回值（基线 db.cj:100-105）。
let n = db.exec(
  "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
  "WHERE id = ? AND version = ? AND remain_num > 0",
  [DbInt(sid), DbInt(ver)])

if (n == 1) {
  // 抢到号 → 写挂号单（同事务）
} else {
  // 号源已变 → 明确失败或重读 version 后重试
}
```

**四个不可动摇的细节**：

| # | 细节 | 理由 |
| --- | --- | --- |
| ① | `remain_num = remain_num - 1` 走**参数化 SQL 文本**，不用 `UpdateQuery.set()` | `set` **只接受值、不接受列表达式**（基线 `dbquery.cj:492-556`）；需要列表达式时必须 `dbRaw`/手写 SQL（`dbquery.cj:89`） |
| ② | 判定成败**只看 `exec` 返回的受影响行数 `n`**，不先 `SELECT` 再 `UPDATE` | 先读后写会把原子操作拆成竞态窗口（TOCTOU） |
| ③ | `UPDATE` 与挂号单 `INSERT` **同一个 `withTransaction`** | 否则会出现"扣了号没挂号单"或反之 |
| ④ | 幂等键 `idemKey("booking", patientId, clientToken)` **在事务内**先查后写 | 客户端重试不得产生第二张挂号单（基线 `store.cj:136` / `store_queries.cj:373`） |

### 2.3 为什么新表不会被整体替换波及

`writeDbToMysql(s, cur)` 只遍历 `Snapshot.entities` 里的表（基线 `mysql_store.cj:1097`）。
**新表不进 `PersistedState` ⇒ 整体替换不会碰它 ⇒ 无双写冲突。**

> ⚠️ 此推论**基于 `mysql_store.cj` 的替换语义阅读得出，属推断**（`smart-hospital-project-brief.md`
> §附录C 推断 2 原话：**「建议落地即写测试钉住」**）。
> **验收条件 AC-4 就是钉住它的回归测试** —— 见 §5。

---

## 3. 备选方案与否决理由（Alternatives）

| 方案 | 做法 | 否决理由 |
| --- | --- | --- |
| **A. 塞进内存 Store**（照旧范式） | `schedule` 进 `PersistedState`，扣减在 `s.lock` 内改内存 | ❌ 三个代价全中（§1.3）；且与参考系统的乐观锁设计**正面冲突** |
| **B. 号源独立域 + Redis 预扣** | Redis 原子 `DECR` + 异步落库 | ❌ 决策 #3 已定**单院区单实例**，**不需要 Redis**；引入 Redis 等于新增一个必须运维的有状态组件，收益不成立 |
| **C. MySQL 悲观锁**（`SELECT ... FOR UPDATE`） | 行锁串行化 | 🟡 **可行但不选**：单院区量级下与乐观锁性能差距很小，但悲观锁会**长时间持有行锁**，与 `withTransaction` 一起更容易在热点号源上排队。乐观锁在"冲突少"的挂号场景更合适，且与参考系统口径一致 |
| **D. 本项目选定：独立域 + 乐观锁原子 UPDATE** | §2.2 | ✅ **采用** |

> 备注：方案 C 是我们**保留的后手** —— 若 Q5（日门诊量 / 号源放出峰值并发）实测显示
> 乐观锁重试率过高，可局部改为 `SELECT ... FOR UPDATE`，**不影响本 ADR 的其余部分**。

---

## 4. 后果（Consequences）

### 4.1 正面

- 挂号扣减是**单条原子 SQL**，并发安全由数据库保证，不依赖应用层锁；
- 整库刷盘（`writeDbToMysql`）**不会**因为挂号而重写排班表 —— 写放大被切断；
- `s.lock` **不参与**挂号路径，挂号不再与其它业务的刷盘争锁；
- 单院区单实例部署下无需 Redis。

### 4.2 负面 —— 必须写进 ADR 的架构债

> 🔴 **服务端从此有两种数据访问范式。**

| 范式 | 适用域 | 权威 | 一致性手段 |
| --- | --- | --- | --- |
| **内存 Store**（原范式） | 科室、医生、患者档案、病历…… | 内存 → 定期整体刷 MySQL | 全局锁 |
| **直接 SQL**（本 ADR） | **仅**号源、挂号单 | MySQL | 乐观锁 + 事务 |

**这是明确的架构债**（`smart-hospital-project-brief.md` §9 **R-2**）。代价：

1. 开发者要**判断某个域该走哪条路** —— 判断错误会产生难查的 bug；
2. 两套数据访问代码的存在，使"新人上手成本"上升；
3. 跨范式的**跨域事务不可行**（例如"扣号 + 写病历"不能同事务）—— 必须避免设计出这种操作。

### 4.3 风险控制（把债关进笼子）

| 控制 | 做法 |
| --- | --- |
| **范围锁死** | 直接 SQL **仅限** `BookingRepo` 拥有的 3 张表：业务状态 `schedule` / `appointment` + 幂等基础设施 `booking_idem`。新增表必须再开 ADR |
| **测试钉住** | AC-4 结构性断言（表名零交集）+ AC-8（`booking_idem` 端到端可用）；完整回归待 P1 |
| **文档标注** | `server/src/` 中走直接 SQL 的文件，文件头注释必须指向本 ADR |
| **禁止跨范式事务** | Code review 检查项：不得出现"内存 Store 变更 + 直接 SQL 变更"同一业务事务 |

#### 4.3.1 ⚠ 口径修订（2026-10-07 复查）：把「域」拆成两层

**原表述有问题**：原文写「直接 SQL **仅限** `schedule`/`appointment` 两张表」，
但 `BookingRepo.putIdem()` / `pruneIdem()` **确实**对第三张表写了直接 SQL；
而 `selftest` 又断言该表「不属号源域」—— **断言与实现的口径在打架**。
（当时 `book()` 并不调用 `putIdem`，幂等靠 `appointment.client_token` 唯一索引 + 先查兜底，
所以**没有功能缺陷**，但这是明确的口径隐患。）

**修订后的划分**（代码里 `BOOKING_DOMAIN_TABLES` / `BOOKING_INFRA_TABLES` 两个常量即此口径）：

| 层 | 表 | 性质 | 走直接 SQL？ |
| --- | --- | --- | --- |
| **业务状态** | `schedule`、`appointment` | 有业务语义、需乐观锁与事务 | ✅ |
| **幂等基础设施** | `booking_idem` | 只是"这个 token 处理过了"的记录，**不是业务状态** | ✅（但仅由 `BookingRepo` 写） |
| **其它业务** | `department`/`doctor`/`patient`/`medical_record` | 走内存 Store 范式 | ❌ |

本 ADR 的「直接 SQL」约束因此精确为：**直接 SQL 只准落在这 3 张表上，且只准由 `BookingRepo` 写**
（`isBookingOwnedTable()` 是可执行的判定）。
—— 新增第 4 张仍然必须先开新 ADR：**约束的强度没变，只是把"业务状态"与"基础设施"说清楚。**

#### 4.3.2 ★ 表名与基线内存 Store 的撞名（P1 阻断项，已在 P0 修掉）

基线内存 Store 自己有一张 **`idem`** 表（`baseline/server/src/mysql_store.cj:892`
的 `PersistedState.idem`；DDL 同名，该文件 §309-311 明说「表名与 `store.cj` 的逻辑表名**一一同名**」）。
基线完整表名集合是：
`departments` `members` `plans` `tasks` `invite_links` `tokens` `idem` `meta` `meta_str` `schema_version`。

本侧原本也叫 `idem`，**两张表的语义与列定义都不同**（基线是 `IdemRecord`；本侧是 `idem_key`+`created_at`）。
P1 引入内存 Store 后，整库刷盘的 `replaceBatched("idem", …)` 会与本侧的挂号幂等记录**争同一张表**。

> **处置：本侧改名为 `booking_idem`。** 现在「本侧 7 张业务表 ∩ 基线 10 张表 = ∅」，
> 由 `selftest` 与 AC-4 双重断言钉住（改名若回退，两条断言当场变红）。
>
> ~~原 AC-4 只比 `BOOKING_DOMAIN_TABLES`（2 张）与基线的交集~~ —— 那**恰好**是 0，
> 但**漏掉了 `booking_idem` 这处真撞名**。现已改为比**全部业务表**与基线**全部**表名。

---

## 5. 验收条件（Acceptance Criteria · 可测试）

| # | 验收条件 | 测试方式 | 状态 |
| --- | --- | --- | --- |
| **AC-1** | 同一 `version` 的两个并发扣减，**恰好一个**成功（`n=1`），另一个 `n=0` | 单测：固定 version 连发两次 `UPDATE`，断言 `n` 序列为 `[1, 0]` | ✅ **PASS** |
| **AC-2** | `remain_num = 0` 时扣减必然失败（`n=0`），**绝不出现负数** | 单测：置 `remain_num=0` 后扣减，断言 `n=0` 且库中仍为 0 | ✅ **PASS** |
| **AC-3** | 同一 `client_token` 重复提交，**只产生一张挂号单** | 单测：同 token 连续两次 `book()`，断言第二次返回既有单、`COUNT(*)=1` | ✅ **PASS** |
| **AC-4** | ★ **整体替换刷盘后，`schedule`/`appointment` 数据不变** | 回归测试：写新表 → 调 `writeDbToMysql` → 重读新表断言逐值相等 | 🟡 **部分**（结构性已验，完整回归待 P1） |
| **AC-5** | 挂号失败（`n=0`）时**不留下部分状态**（无挂号单、号源数不变） | 单测：制造 version 冲突后断言两表均未变 | ✅ **PASS** |
| **AC-6** | `visit_date` **就诊日快照**：顺延排班后，已挂号单的 `visit_date` 不变 | 单测：挂号 → 改 `schedule.work_date` → 断言挂号单 `visit_date` 仍是原值 | ✅ **PASS** |
| **AC-7** | ★ 退号：**取消成功必须如实上报** —— 归还失败时不得谎报"取消失败" | 单测：制造 `remain_num == total_num` 后 `cancel()`，断言返回 `SlotNotRestored` **且**挂号单确已 `cancelled` | ✅ **PASS** |
| **AC-8** | `booking_idem` 改名后**端到端可用**（登记/去重/过期清理） | 单测：`putIdem` 两次断言 `true/false`、`COUNT(*)=1`、`pruneIdem` 删除生效 | ✅ **PASS** |

**实测记录（2026-10-07，含复查修复）**：`hospital-server.exe accept <dsn>` →
**通过 32 项 / 失败 0 项**；`selftest` → **29 项** schema 断言全通过。

> **AC-1 的验证边界（不冒充并发测试）**：本仓库通篇没有 `spawn`，故 AC-1 验证的是
> **数据库层原子性**（同一 version 的第二次 UPDATE 必返回 0 行）—— 这是并发安全的**根因**，
> 但不是多线程并发测试。真正的并发压测应在 P1 有了 HTTP 接口后、用多个独立进程打同一号源。
>
> **AC-4 的验证边界**：P0 尚未引入内存 Store，故只完成**结构性**验证
> （**全部 7 张业务表**与基线**全部 10 张表**名零交集 ⇒ 整体替换不会遍历到它们）。
> 完整回归（真的跑一次整库刷盘再断言逐值不变）排在 P1。
>
> **AC-7 的由来**：这是 2026-10-07 复查发现并修掉的**真缺陷**。原 `cancel()` 返回
> `tx.cancelDone && tx.released`，当 `releaseSlotFor` 失败（如管理员重置过号源使
> `remain_num == total_num`）时，事务**已提交** —— 单子取消了、号没还回，却对外报 `false`，
> 调用方会误以为"取消失败"从而重复重试或误导用户。已改为三态 `CancelOutcome`
> （`Cancelled` / `SlotNotRestored` / `NotFound`），并补 AC-7 钉住。
>
> **测试有效性已用变异测试证明**：把 `AND version = ?` 中性化为 `AND (version = ? OR 1 = 1)`
> 后（保留参数个数），AC-1 当场报 3 条 `[FAIL]`；恢复后重新全绿。
> 首次尝试变异时因参数个数不匹配导致 `bindSql` 抛异常、测试**静默中断**，
> 这促使我们给测试加了 `section()` 异常兜底 —— **失败必须被说出来，不能靠崩溃表达。**
>
> ⚠ 状态说明：**不存在**原始草稿中的「否则本 ADR 降级为 Proposed」情形 ——
> AC-1/2/3/5/6/7/8 已实测通过，AC-4 的剩余部分有明确的 P1 归属与理由，故本 ADR 维持 **Accepted**。

### 5.1 ⚠ 验收依据：**源码哈希 + 测试**，不是产物哈希

2026-10-07 实测确认：**cjc 的产物不逐字节可复现** —— 同一份源码连续两次构建，
`hospital-server.exe` 的 SHA256 不同（行为一致，属编译器正常现象：内嵌时间戳/路径/布局差异）。

| 对象 | 连续两次构建是否一致 |
| --- | --- |
| `hospital-server.exe` 的 SHA256 | ❌ **不同** |
| `build/SOURCE-MANIFEST.sha256` 的 SHA256（43 个源文件） | ✅ **相同** |

**因此：产物哈希不能当验收依据**，可复现的锚点是
**`build/SOURCE-MANIFEST.sha256`（记录每个参与编译源文件的 SHA256 + cjc 版本 + stdx 路径 + 驱动产物哈希）
配合测试结果**。`build.ps1` 每次构建都会重写该清单，口径与基线 `MANIFEST.sha256` 一致。

---

## 6. 调参项（Tuning Knobs · 带安全范围）

| 参数 | 含义 | 安全范围 | 说明 |
| --- | --- | --- | --- |
| `MAX_BOOKING_RETRY` | 乐观锁冲突后的重试次数 | **1 – 3**（默认 **2**） | 超过 3 次说明热点冲突严重，应改用方案 C 或加排队，**不要靠加重量次数掩盖** |
| 幂等窗口 | `idemKey` 去重有效期 | **24h** | 与基线一致便于复用；表落在本侧 `booking_idem`（**不叫** `idem`，见 §4.3.2） |
| 号源放出上限 | 单排班 `remain_num` 上限 | 建议 **≤ 200** | 超过则单行成为热点行，需按 Q5 实测决定是否分段 |
| 事务超时 | `withTransaction` 允许时长 | **≤ 3s** | 事务内**禁止**调用外部模型/HTTP —— 见下 |

🚫 **铁律**：`withTransaction` 内**绝不允许**出站网络调用（AI 模型/HTTP）。
基线已立此纪律（`h_ai.cj` 的 `aiAgentLoop`：锁外调模型 → 锁内跑 1 个工具 → 锁外回灌）。
挂号事务里同理 —— **不允许"调 AI 判断该挂哪个科"再扣号**。

---

## 7. 落地清单（P0 交付物）

| # | 交付物 | 落点 |
| --- | --- | --- |
| 1 | 本 ADR | `docs/adr/ADR-0001-号源与挂号独立MySQL路径.md` |
| 2 | 最小表集 DDL | `server/src/schema.cj`（`SCHEMA_DDL`） |
| 3 | 号源/挂号域实现（含原子扣减 + 幂等） | `server/src/domain_booking.cj` |
| 4 | 验收测试 AC-1…AC-8 | `server/src/acceptance.cj`（**不是** `server/tests/` —— 该目录在 P0 并未创建，验收测试作为源文件编进 exe，经 `accept` 子命令运行） |
| 5 | 构建链（cjc 1.2.0 + stdx 1.1.3.1） | `server/build.ps1` |
| 6 | 源码哈希清单（验收锚点，替代不可复现的产物哈希） | `server/build/SOURCE-MANIFEST.sha256`（由 `build.ps1` 生成） |

---

## 8. 复审触发条件

出现以下任一情况时，本 ADR **必须复审**：

1. 实测挂号峰值并发使 `MAX_BOOKING_RETRY` 耗尽率 > 1% → 重估方案 C；
2. 需要**跨域事务**（挂号与病历/支付同时原子）→ 双范式方案本身破产，需重新设计；
3. 引入**第二个号源写入方**（如 HIS 对接）→ 乐观锁假设（唯一写方）不再成立；
4. 需要**水平扩展**（突破决策 #3 单实例）→ 内存 Store 与直接 SQL 的边界要重新划；
5. 本侧需要**第 4 张**走直接 SQL 的表 → 必须回到 §4.3 重新论证并扩写范围锁死清单。

---

*本 ADR 遵循 `~/.dsh/AGENTS.md`「每个系统有架构决策记录（ADR）」要求，
记录**为什么**而非仅记录**做什么**。*
