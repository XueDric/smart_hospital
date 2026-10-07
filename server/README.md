# 智慧医院服务端（仓颉 + 轻舟）

> P0 阶段交付：**号源/挂号域的独立 MySQL 路径** + 构建链 + 验收测试。
> 架构决策见 [../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)。

---

## 一、环境事实（本机实测）

| 项 | 值 | 说明 |
| --- | --- | --- |
| 编译器 | **cjc 1.2.0** | `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie` |
| ⚠ PATH 上的 cjc | **1.1.3**（`D:\Cangjie`） | **是旧版、不可用**。版本串台症状 = 编译中途 `LLVM ERROR: Broken module found` |
| stdx | **1.1.3.1 静态** | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 数据库 | **MariaDB 11.4.13**（便携版）@ `127.0.0.1:3307` | `E:\cangjie\mariadb\mariadb-11.4.13-winx64` |
| 业务库 / 账号 | `hospital` / `hospital` 口令 `hospital_dev_2026` | ⚠ 开发口令，**上生产必须换** |
| Shell | **Windows PowerShell 5.1** | ⚠ 含中文的 `.ps1` **必须 UTF-8 with BOM**，否则 PS 5.1 按 ANSI 解析会**语法报错** |

> `build.ps1` 会**按版本挑 1.2.0**，不盲信 PATH —— 这一点很重要，见上表第 2 行。

---

## 二、构建

```powershell
cd server
.\build.ps1
```

首次构建前需先生成 MariaDB 驱动产物（**只做一次**）：

```powershell
cd server
.\build-mysql-driver.ps1 `
  -CangjieHome 'C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie' `
  -Stdx 'E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx'
```

产物：`build\hospital-server.exe` + 运行时依赖 4 个 DLL（`setup-runtime.ps1` 负责就位）
+ `build\SOURCE-MANIFEST.sha256`（验收锚点）。

### 为什么不用 cjpm

驱动自己的 `cjpm.toml` 没声明 stdx 包，`cjpm build` 会强校验并报
`imports package 'stdx.crypto.digest' ... not added as a dependency`。
基线已踩过此坑（见 `baseline/docs/mysql-backend.md` §3.3），故沿用 **cjc 直编、框架与业务同一次调用、同一个包**。

---

## 三、运行

```powershell
cd server     # ⚠ cwd 必须是 server/，见下
.\build\hospital-server.exe selftest
.\build\hospital-server.exe check-db "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"
.\build\hospital-server.exe accept   "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"
```

| 子命令 | 作用 | 需要 MySQL |
| --- | --- | --- |
| `selftest` | schema 与 ADR 不变量的**纯本地**自检（29 项断言） | ❌ |
| `check-db <dsn>` | 连库 + 幂等建表 + 打印表清单（★ 标记号源域） | ✅ |
| `accept <dsn>` | P0 验收测试 AC-1…AC-8（32 项断言） | ✅ |

⚠ `accept` **会清空业务表**，已内置库名守卫（库名不含 `test` 且不等于 `hospital` 时中止）。

### 验收依据：源码哈希，不是产物哈希

cjc 的产物**不逐字节可复现**（实测：同一份源码连续两次构建，exe 的 SHA256 不同，行为一致）。
所以 `build.ps1` 每次构建都会重写 **`build/SOURCE-MANIFEST.sha256`**（43 个参与编译源文件的
SHA256 + cjc 版本 + stdx 路径 + 驱动产物哈希）—— 它的哈希是**稳定**的。
**验收请比 `SOURCE-MANIFEST.sha256` + 测试结果，不要比 exe 哈希。**

---

## 四、P0 已交付内容

| 文件 | 职责 |
| --- | --- |
| `src/schema.cj` | 最小表集 DDL（7 张）+ 两层范围锁死（业务状态 / 幂等基础设施） |
| `src/domain_booking.cj` | ★ 号源/挂号域：原子扣减、幂等、取消归还（三态 `CancelOutcome`）、`visit_date` 快照 |
| `src/db_bootstrap.cj` | MySQL 建连 + `SET NAMES utf8mb4` + DSN 解析 + 驱动注册 |
| `src/acceptance.cj` | AC-1…AC-8 验收测试（含异常兜底与变异测试记录） |
| `src/main.cj` | 进程入口与子命令分发 |

**最小表集（7 张）**：

| 表 | 层 | 数据访问 |
| --- | --- | --- |
| `schedule` | 号源域 · **业务状态** | 直接 SQL |
| `appointment` | 挂号域 · **业务状态** | 直接 SQL |
| `booking_idem` | 号源域 · **幂等基础设施** | 直接 SQL（仅 `BookingRepo` 写） |
| `department` `doctor` `patient` `medical_record` | 业务 | 内存 Store 范式（P1+ 落地） |

> ⚠ `booking_idem` **刻意不叫** `idem`：基线内存 Store 已占用 `idem` 表名
> （`baseline/server/src/mysql_store.cj:892`，列定义不同）。P1 引入内存 Store 后
> 整库刷盘的 `replaceBatched("idem", …)` 会与本侧挂号幂等记录争同一张表。
> 现「本侧 7 张表 ∩ 基线 10 张表 = ∅」，由 `selftest` + AC-4 钉住。

---

## 五、P0 踩过的坑（都已解决，写下来省下次时间）

1. **PS 5.1 + 无 BOM 的中文 `.ps1`** → 脚本语法报错（不是编码乱码那么轻）。
   处置：**所有含中文的 `.ps1` 存成 UTF-8 with BOM**（本目录 `build.ps1`、`build-mysql-driver.ps1` 已带 BOM）。
2. **PATH 上的 cjc 是 1.1.3**，`CANGJIE_HOME` 也可能被 cjenv 改写成旧版。
   处置：`build.ps1` 按 **版本号**挑 1.2.0，而不是按位置。
3. **`exec()` 返回的是受影响行数，不是自增 id**。
   把 `INSERT` 的返回值当 id 用 → 所有新单 id 都是 1 → AC-3/AC-6 **假通过/查询错行**。
   处置：INSERT 后紧跟 `SELECT LAST_INSERT_ID()`。**这坑是验收测试抓出来的。**
4. **驱动必须在被编译的文件里 `import` 才会注册**（仅 `-l:` 链接不够）。
   处置：`db_bootstrap.cj` 顶层 `import mariadb.cdbc.*`。
5. **仓颉闭包不能捕获外部可变 `var`**，甚至**传递性**捕获也不行
   （`lambda captured a mutable variable transitively, lambda cannot be used as a param`）。
   处置：结果装在 class 的 `var` 字段里回传（`TxResult`、`TestRunner`）。
6. **`match` 的分支体是单表达式**，不能写多语句块。
   处置：多语句分支改用 `if` 链。
7. **没有 `String.substring`**，用范围切片 `s[a..b]` / `s[n..]`。
8. **`indexOf` / `lastIndexOf` 返回 `?Int64`**（不是 -1 哨兵），要与 `Int64` 比较必须先 `isNone()`/`getOrThrow()`。
9. **`Int64.parse` 需要 `import std.convert.*`**。
10. **`SET NAMES utf8mb4` 不能省**：驱动握手把会话字符集写死成 utf8mb3，
    一个 emoji 就会让之后**所有写入持续 500** 直到重启（基线 API-NOTES 坑 44）。
11. **OpenSSL 3 DLL 必须与 exe 同目录**，否则运行时 `CryptoException: Can not load openssl library`。
    处置：`setup-runtime.ps1`。
12. **`SELECT LAST_INSERT_ID()` 与 MySQL `AUTO_INCREMENT` 起点**：清表用 `DELETE` 不重置自增，
    所以测试用**显式 id**，避免依赖自增序列。
13. **`cancel()` 不能用 `Bool` 表达结果**：把"单子取消了"与"号还回去了"压进一个 bool，
    必然丢掉"单已取消但号未归还"这一真实中间态，于是对外**报错方向与事实相反**
    （已改为三态 `CancelOutcome`，AC-7 钉住）。
14. **产物哈希不能当验收依据**：cjc 输出不逐字节可复现；用 `SOURCE-MANIFEST.sha256` + 测试。
15. **表名要与基线内存 Store 错开**：基线占用了
    `departments/members/plans/tasks/invite_links/tokens/idem/meta/meta_str/schema_version`，
    新建表前先比对，否则 P1 整库刷盘会争表。

---

## 六、明确**未**做（P1+）

- ❌ HTTP 路由与接口（P1 挂号闭环）——P0 刻意不先写空壳 `listen`，避免"看起来能跑其实没接口"。
- ❌ 认证/鉴权三端角色（P1）
- ❌ 内存 Store 范式（科室/医生/病历）—— AC-4 的完整回归依赖它
- ❌ AI 分诊与预问诊 SSE（P2/P4）
- ❌ 多进程并发压测（P1 接口就绪后）
