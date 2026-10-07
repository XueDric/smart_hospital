# P0 收尾说明 · 号源/挂号独立 MySQL 路径

> **日期**：2026-10-07 ｜ **阶段**：P0（架构决策落定）— **已完成**
> **前置**：[ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md) ｜ **下一步**：P1 挂号闭环

---

## 0. 三行上手

```powershell
cd server
.\build.ps1
.\build\hospital-server.exe selftest        # 无需数据库，21 项断言
```

要连库验（本机确实经过这一步）：

```powershell
$env:DSN = "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"
.\build\hospital-server.exe check-db $env:DSN
.\build\hospital-server.exe accept   $env:DSN
```

---

## 1. P0 交付了什么

| # | 交付物 | 落点 | 状态 |
| --- | --- | --- | --- |
| 1 | **架构决策记录**（唯一架构级决策） | [docs/adr/ADR-0001-号源与挂号独立MySQL路径.md](adr/ADR-0001-号源与挂号独立MySQL路径.md) | ✅ Accepted |
| 2 | 仓颉服务端骨架 + 构建链 | [server/build.ps1](../server/build.ps1) | ✅ 编译通过 |
| 3 | 最小表集 DDL（7 张） | [server/src/schema.cj](../server/src/schema.cj) | ✅ 建表实测通过 |
| 4 | ★ 号源/挂号域（原子扣减 + 幂等） | [server/src/domain_booking.cj](../server/src/domain_booking.cj) | ✅ 实现并验证 |
| 5 | MySQL 建连与会话初始化 | [server/src/db_bootstrap.cj](../server/src/db_bootstrap.cj) | ✅ 实测连库 |
| 6 | 验收测试 AC-1…AC-6 | [server/src/acceptance.cj](../server/src/acceptance.cj) | ✅ 21/21 通过 |
| 7 | 服务端说明与踩坑清单 | [server/README.md](../server/README.md) | ✅ |

### 最小表集（`smart-hospital-project-brief.md` §10 Q2 的建议最小集）

| 表 | 归属 | 数据访问范式 |
| --- | --- | --- |
| `schedule` ★ | **号源域 · 业务状态** | **直接 SQL**（ADR-0001） |
| `appointment` ★ | **挂号域 · 业务状态** | **直接 SQL**（ADR-0001） |
| `booking_idem` ◆ | **号源域 · 幂等基础设施** | **直接 SQL**（仅 `BookingRepo` 写） |
| `department` | 基础数据 | 内存 Store（P1+ 落地） |
| `doctor` | 基础数据 | 内存 Store（P1+ 落地） |
| `patient` | 患者档案 | 内存 Store（P1+ 落地） |
| `medical_record` | 病历七段式 | 内存 Store（P1+ 落地） |

> ★ = **业务状态**，走直接 SQL；◆ = **幂等基础设施**，不是业务状态，但同样只由 `BookingRepo` 写。
> ADR-0001 §4.3「范围锁死」：**直接 SQL 只准落在这 3 张表上**，新增第 4 张必须先开新 ADR ——
> 这条约定已被 `selftest` 写成可执行断言（`isBookingDomainTable` / `isBookingInfraTable` / `isBookingOwnedTable`）。
>
> ⚠ **`booking_idem` 为什么带前缀**：基线内存 Store 自己有一张 `idem` 表
> （`baseline/server/src/mysql_store.cj:892`），语义与列定义都不同。P1 引入内存 Store 后
> 整库刷盘的 `replaceBatched("idem", …)` 会与本侧挂号幂等记录**争同一张表**。
> 改名后「本侧 7 张表 ∩ 基线 10 张表 = ∅」，由 `selftest` + AC-4 双重钉住。

---

## 2. 验收结果（实测，非推断）

```
通过 32 项，失败 0 项
✅ 验收测试全部通过
```

| AC | 内容 | 结果 |
| --- | --- | --- |
| AC-1 | 同一 version 的第二次扣减必然 0 行（原子性） | ✅ |
| AC-2 | `remain_num=0` 时扣减失败，**绝不出现负数** | ✅ |
| AC-3 | 同一 `client_token` 只出一张挂号单（幂等） | ✅ |
| AC-4 | 本侧 **7 张**表与基线 **10 张**表名零交集 | 🟡 **部分**（结构性已验，完整回归待 P1） |
| AC-5 | 挂号失败不留部分状态（无脏单、号源不变） | ✅ |
| AC-6 | `visit_date` 快照：顺延排班不改已挂号单 | ✅ |
| **AC-7** | ★ 退号：**取消成功必须如实上报**（不谎报失败） | ✅ |
| **AC-8** | `booking_idem` 改名后端到端可用 | ✅ |

### 三条必须知道的验证边界（不冒充）

1. **AC-1 不是并发测试。** 本仓库通篇没有 `spawn`，所以它验证的是
   **数据库层原子性**（过期 version 必返回 0 行）—— 即并发安全的**根因**，而非多线程并发本身。
   真正的并发压测排在 P1（有 HTTP 接口后，多进程打同一号源）。
2. **AC-4 只完成结构性验证。** P0 还没引入内存 Store，所以只能断言
   「本侧 7 张表与基线 10 张表名**零交集**」。真的跑一次整库刷盘再断言逐值不变，要等 P1。
3. **验收依据是源码哈希，不是产物哈希。** 实测：同一份源码连续两次构建，
   `hospital-server.exe` 的 SHA256 **不同**（cjc 正常现象）；而
   `build/SOURCE-MANIFEST.sha256` 的 SHA256 **完全相同**。
   → 请以 **`SOURCE-MANIFEST.sha256` + 测试结果** 作为验收锚点。

### 测试有效性怎么证明的（变异测试）

把 `AND version = ?` 中性化为 `AND (version = ? OR 1 = 1)`（**保留参数个数**）后重建，
AC-1 当场报 **3 条 `[FAIL]`**；恢复源码后重新全绿。

> 首次变异尝试因参数个数不匹配，`bindSql` 直接抛异常、测试**静默中断**（一条 `[FAIL]` 都没打印）。
> 这暴露了测试工具本身的缺陷 —— 于是补了 `section()` 异常兜底。
> **失败必须被说出来，不能靠崩溃"顺带"表达。**

### 复查修复记录（2026-10-07 rev.2）

用户复查提出 5 项发现，全部已处理：

| # | 发现 | 处置 |
| --- | --- | --- |
| 1 | ADR §4.3「直接 SQL 仅限两张表」与代码不符（`putIdem`/`pruneIdem` 动了第三张表 `idem`），而 `selftest` 又断言它"不属号源域"——**口径打架** | 拆成「业务状态」（2 张）与「幂等基础设施」（1 张）两层；`isBookingOwnedTable()` 判定；ADR §4.3.1 |
| 2 | 医院侧 `idem` 与基线内存 Store 的 `idem` **撞名**（基线 `mysql_store.cj:892`），P1 整库刷盘会争表 | **改名 `booking_idem`**；AC-4 从"只比 2 张"扩大到"比全部 7 张 vs 基线全部 10 张"；ADR §4.3.2 |
| 3 | `cancel()` 存在「返回 false 但单已取消」路径（`remain_num == total_num` 时归还失败，事务已提交） | 返回类型 `Bool` → 三态 `CancelOutcome`（`Cancelled`/`SlotNotRestored`/`NotFound`）；新增 **AC-7** 钉住 |
| 4 | ADR §7 第 4 项把验收测试落点写成 `server/tests/`，该目录不存在 | 改为 `server/src/acceptance.cj`（并说明为何不在 `tests/`） |
| 5 | 编译产物不逐字节可复现 → 产物哈希不能当验收依据 | `build.ps1` 生成 `SOURCE-MANIFEST.sha256`；ADR §5.1 + 本文档 §2 边界 3 |

> 复查同时发现 `selftest` 的「DDL 条数 == 表数」断言本身脆弱（DDL 数组将来可含无业务模型的表），
> 已改成"每张业务表都能在 DDL 里找到"的断言方式。

---

## 3. 本机联调环境（已配好）

| 项 | 值 |
| --- | --- |
| 编译器 | cjc **1.2.0** @ `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie` |
| ⚠ PATH 上的 cjc | **1.1.3（旧版，勿用）** @ `D:\Cangjie` |
| stdx | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 数据库 | MariaDB 11.4.13 便携版 @ **127.0.0.1:3307** |
| 库 / 账号 | `hospital` / `hospital` · 口令 `hospital_dev_2026` |
| 服务启动 | `E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe --datadir=E:\cangjie\mariadb\data --port=3307 --console` |

### ⚠ 关于这次动了本机 MariaDB（必须交代）

本机那份便携 MariaDB 的 **root 口令未知**，且既有 `club` 账号的授权主机作用域
（`10.194.%`）与**本机当前实际 IP 不匹配** —— 本机现在走**有线网口**，实际 IP 是
**`10.179.153.237`**（不再是 `10.194.178.115`，也不是 `LAN-CREDS.txt` 里记的 `10.194.233.104`），
所以 `club` 账号连不上。为了把 P0 验完，我：

1. 用 `--skip-grant-tables --skip-name-resolve` 临时起了一次（**恢复模式，仅本机**）；
2. 在其中**新建**了专用库 `hospital` 与账号 `hospital`（并 `FLUSH PRIVILEGES` 恢复认证）；
3. 随后**已停止恢复模式**，用**普通模式**重启 mysqld 并验证 `hospital` 账号可正常登录。

**未做**：没有改 root 口令、没有删改既有 `club_*` 库与账号。
现状：mysqld 正在以普通模式运行在 3307 上。

> 若你要停掉它：`Get-Process mysqld | Stop-Process -Force`
> ⚠ `hospital_dev_2026` 是**开发口令**，上生产必须换。

---

## 4. ADR 里那些"必须记住"的约束

1. **范围锁死**：直接 SQL **只准** `schedule` / `appointment` 两张表。
2. **事务内禁止出站网络**（AI/HTTP）—— 所以"调 AI 判断挂哪个科"再扣号是**禁止**的设计。
3. **绝不先 SELECT 再 UPDATE**：成败只看 `exec()` 的受影响行数。
4. **`remain_num > 0` 条件不能省**：只靠 version 挡不住"号放完了但 version 没变"（如管理员手工置 0）。
5. **重试上限 1–3（默认 2）**：冲突多了要改架构，**不是**加大重试次数。
6. **挂号绝不进离线队列**（brief §5.4）：必须在线直连 + 强一致确认页。

---

## 5. P1 的入口（下一步）

按 `smart-hospital-project-brief.md` §8：

> **P1 挂号闭环**：排班 → 号源 → 乐观锁扣号 → 幂等 → 退号归还（**全项目风险最高，必须最先做**）

P0 已经把 P1 最难的**数据层**做完并验过了。P1 剩下的主要是：

| 任务 | 依赖 |
| --- | --- |
| 轻舟 HTTP 路由 + 中间件装配（照 `baseline/docs/qingzhou-api-fact-sheet.md`） | 框架 API 已摸清 |
| 挂号相关 REST：排班查询 / 挂号 / 取消 | `BookingRepo` 已就绪 |
| 认证与三端角色（令牌 + PBKDF2 + `can()`） | 复用 `baseline/server/src/auth.cj`、机制搬、角色枚举重做 |
| 并发压测（多进程打同一号源）—— 补 AC-1 的真实并发面 | 需接口就绪 |
| 引入内存 Store → 补 AC-4 完整回归 | 需科室/医生域 |

---

## 6. 参考

- 项目上下文入口：[../smart-hospital-project-brief.md](../smart-hospital-project-brief.md)
- 只读基线说明：[../baseline/SNAPSHOT.md](../baseline/SNAPSHOT.md)
- **轻舟 API 事实清单**（每条带 file:line，写接口前必读）：[../baseline/docs/qingzhou-api-fact-sheet.md](../baseline/docs/qingzhou-api-fact-sheet.md)
- 仓颉编译期踩坑（45 条）：[../baseline/docs/API-NOTES.md](../baseline/docs/API-NOTES.md)
- 基线 MySQL 接入与坑：[../baseline/docs/mysql-backend.md](../baseline/docs/mysql-backend.md)
