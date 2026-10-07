# 容量基准与四项性能改造（服务端）

> 📁 **容量基准与性能改造** ｜ 本文件：`capacity-baseline.md` ｜ [全部文档目录](README.md)

> 面向问题："社团成员预计会接近千人，现在的存储扛得住吗？"
> 本文件给出**可复现**的实测数字、四项性能改造各自的真实收益，以及**哪些收益其实没测出来**。

数据全部来自 `server/tests/bench.ps1`（真实 HTTP、真实落盘、中位数 10 次），
"改造前"是在 `git worktree` 里按旧提交编译出来的可执行文件上跑的 —— **同一个脚本、同一种数据形状，只有被测代码不同**。

> ⚠ **读前必看（2026-10-04）**：本文所有性能数字与"整库落盘 / 每次写都重写整个 `db.json`"的分析都来自
> **文件后端**（`data/db.json`）。club-server 自 **2026-09-20** 起持久化已换成 **MySQL/MariaDB**
> （`server/src/mysql_store.cj`，增量事务落盘，见 `docs/mysql-backend.md` §十二）——
> 下面那些数字仍是当时的实测基线，但"每次写都重写整个 `db.json`"这条天花板**对现在的运行期不成立**。

---

## 1. 一句话结论

| 结论 | 依据 |
| --- | --- |
| **千人规模（1000 成员 + 1000 任务 ≈ 0.5 MB 库）单机绰绰有余** | 列表 30 ms 级、写 30 ms 级、4 并发登录 ~0.9 s |
| 四项改造里**只有"PBKDF2 移出锁"有量级收益** | 4 并发登录 **1574 → 867 ms**（串行因子 0.99 → 0.56） |
| 排序改造与落盘改造在本基准规模下**落在噪声内** | 见 §3.1 / §3.4，**不要当性能成果宣传** |
| 真正的容量天花板是"**每次写都重写整个 db.json**" | 写盘量 ≈ 3 × 文件大小，随成员数线性增长 |
| 登录 ~400 ms 是**设计选择**不是缺陷 | 10 万次 PBKDF2 迭代，四并发下不再互相排队（§3.2） |

瓶颈从大到小：**① PBKDF2（CPU）→ ② 整库序列化 + 写盘（线性）→ ③ 列表排序（n log n）**。
近千人规模下三者都还不构成问题。

---

## 2. 怎么复现

```powershell
# 1) 改造后
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Members 1000 -Tasks 1000

# 2) 改造前（在旧提交上单独编译一份，不碰当前工作区）
cd ..
git worktree add ..\bench-old HEAD
cd ..\bench-old\server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
cd ..\..\cangjie_web\server
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Members 1000 -Tasks 1000 `
    -Exe ..\bench-old\server\build\club-server.exe
git worktree remove --force ..\bench-old
```

造数方式（脚本里做的事，**不是**手工写 JSON）：

1. `club-server init-admin` 生成一个带**真实口令哈希**的库；
2. 把首任会长那条成员记录**克隆**成 N 条（共用同一份 `pw_salt`/`pw_hash`，于是所有人都是 `password123`）；
3. 起服务、用接口建 **1 条真任务**（保证字段与当前 schema 一致），停服务，再把这条任务克隆成 M 条；
4. 任务的 `due_at` 用 `i * 7919 mod 一年` **打散** —— 这一条很关键，见 §3.1。

> ⚠️ 旧版 `build.ps1` 会把轻舟的 `src/store.cj`、`src/rbac.cj` 一起编译（那两个文件 `import cangdb.*`），
> 所以对比时要把当前 `build.ps1` 复制进 worktree 再编译。

---

## 3. 实测矩阵

单位 ms，中位数 10 次；并发项 = 4 个请求**同时**发出后量最后一个回来的墙钟时间，
括号里是**串行因子** = 并发墙钟 ÷ (4 × 单发中位数)，越接近 1 越说明被完全串行化。

| 指标 | 改造前 1000 | 改造后 1000 | 改造前 3000 | 改造后 3000 |
| --- | ---: | ---: | ---: | ---: |
| db.json | 0.51 MB | 0.51 MB | 1.54 MB | 1.54 MB |
| 启动就绪 | 80 | 90 | 604 † | 96 |
| `login` 单发 | 399 | 384 | 437 | 406 |
| `tasks` 单发 | 31 | 32 | 32 | 45 |
| `members` 单发 | 31 | 30 | 27 | 47 |
| `write` 单发 | 32 | 31 | 44 | 48 |
| **`login` ×4 并发** | **1574（0.99）** | **867（0.56）** | **1923（1.10）** | **976（0.60）** |
| `write` ×4 并发 | 34（0.27） | 28（0.23） | 104（0.59） | 91（0.47） |

† 离群值：同机重复运行启动就绪在 80–110 ms 之间，604 ms 那一次疑似文件缓存冷启动。
**噪声带：同一配置重复运行波动 ±15 ms** —— 表里任何小于这个幅度的差异都不要解读。

正确的读法：

* **只有第 7 行值得说**：4 并发登录 1574 → 867 ms（1000 档）、1923 → 976 ms（3000 档），
  即 **1.8× / 2.0×**，串行因子 0.99/1.10 → 0.56/0.60 —— 锁外算哈希确实生效了。
* 第 3–6 行的差异**全在噪声带内**（注意 `tasks` 3000 档改造后反而"慢"了 13 ms，那是抖动，不是回归）。
* 1000 → 3000（规模 ×3）时单发只涨 ~1.3–1.6× → 目前**没有明显的超线性**。

---

## 4. 四项改造逐条

### 4.1 动作 1 · 排序：插入排序 → 堆排序

**改了什么**：`store.cj` 的 `sortByKey` 由插入排序换成原地堆排序（`siftDown`），
键函数签名不变，所有调用点（部门/成员/任务/课题/邀请链接）自动受益。

**为什么基准里看不见**：
`GET /tasks` 由 `sortedTasksByDue` 按“有截止优先、截止时间、任务 id”比较，数组来自 `HashMap` 迭代
（int 键连续时大致按 id 升序）。3000 条完全乱序时插入排序约 n²/4 = 2.25M 次比较，
在这个规模上只有**几毫秒**；而这个接口本身要 30–45 ms，绝大部分花在**把 3000 条任务序列化成 JSON** 上。
也就是说：这次改动的收益被"响应体序列化"盖住了。

> 造数时如果把 `due_at` 全留成 0（我第一版就是这样），比较退化成只按 id，
> 插入排序恰好走 O(n) 最好情况 —— 那就更测不出任何东西了。脚本现在会打散 `due_at`。

**真正会被咬的地方**（本基准**没有**覆盖）：`store.cj:1311` 的
`sortByKey<Plan>(arr, { p => 0 - planDepthOf(s, p.id) * 1000000 + p.id })` ——
键闭包每次比较都要**走一遍父链**，代价是 O(n² × 深度)。课题多、层级深时这才是真瓶颈。

**价值定位**：把最坏情况从 O(n²) 拉到 O(n log n)，属于**下界保险**，不是当下的提速项。
**证据**：`testSortEdge`（500 条乱序、100 条同键、单元素、空数组）。

### 4.2 动作 2 · PBKDF2 移出全局锁（三阶段加锁）★ 唯一有量级收益的改动

**改了什么**：`handleRegister` / `handleLogin` / `handleChangePassword` / `handleResetPassword`
统一改成三阶段：

```
加锁 → 只读标量（盐、迭代数、旧哈希、权限位）→ 解锁
→ 锁外算 PBKDF2（10 万次迭代，~400 ms）
→ 再加锁 → **复核**（口令哈希没被并发改过 / 权限仍然成立）→ 才写入
```

**为什么这样安全**：PBKDF2 只依赖 `(password, salt, iter)`，与 `Store` 无关，
所以可以整段搬到锁外；而"写回"必须复核，否则两次并发改密会互相覆盖（`handleLogin` 复核 `m.pw_hash != credHash`，
`handleChangePassword` 先验证旧口令再算新口令，避免成为放大攻击的跳板）。

**实测**：4 并发登录 **1574 → 867 ms**（1000 档）、**1923 → 976 ms**（3000 档）；
串行因子 0.99/1.10 → 0.56/0.60。

**单发没有变快**（~400 ms），这是**对的**：10 万次迭代的固有成本。
如果嫌登录慢，能动的只有迭代次数 —— 那会降低离线爆破成本，属于 `v1-scope` 的设计决定，不在本轮范围。

### 4.3 动作 3 · 过期令牌回收

**改了什么**：新增 `pruneTokens(s, now)`，在 `issueToken` 里顺手回收一次（低频、O(n) 一趟）。

**为什么需要**：`tokens` 表原先**只增不减** —— 只有"某个已过期令牌被再次使用"时才会被删，
用户不再登录就永远留着；而**每次写盘都会把整张表序列化进 db.json**。
按 1500 条 ≈ 165 KB 估算，1200 人社团一学期累积上万条，每次写盘就要多背约 1 MB。

**证据**：`testTokenPrune`（3 条过期 + 2 条活跃 → 回收 3 条；无过期时返回 0 且不动表；
`issueToken` 顺手回收）。用 2286 年当"永不过期"、1970 年当"必然过期"，**不依赖真实时钟**。

**边界**：回收只是**省空间**，鉴权仍然由 `requireMember` 独立判定 —— 表里残留的过期令牌照样会被拒绝。

### 4.4 动作 4 · 整库落盘移出全局锁

**改了什么**：`storeSave` 在锁内只做**取快照**（`storeSnapshot` = 把整个库渲染成 db.json 文本），
写盘交给挂在请求链末端的 `snapshotFlush` 中间件，在**解锁之后**执行；
`save_lock` + `seq`/`saved_seq` 序号守卫保证并发写盘收敛到最新版本（旧快照不会覆盖新快照）。

**为什么"响应 200 ⇒ 已落盘"这条强语义还在**（这是当初把 IO 放进锁里的理由，不能丢）：
轻舟的 `AppHandler.handle` 是**先跑完整条中间件链（含 handler）、最后才 `ctx.commit()` 真正写 socket**
（`server/third_party/qingzhou/src/compose.cj:83-101`、`context.cj:426`）。
`snapshotFlush` 挂在 router **之前**，`next()` 返回时 handler 已经解锁，而 `ctx.commit()` 还没发生：

```
handler 改内存 → finally 解锁 → snapshotFlush 写盘 → dispatch 返回 → ctx.commit() 发响应
```

**为什么不直接改那 26 个 `storeSave` 调用点**：那样必须把"构造响应"也搬出锁，
而响应构造**要读 Store**（`HashMap` 非线程安全，锁外读与写并发是数据竞争）。
中间件方案**零调用点改动**、语义不变，还自动覆盖将来新写的 handler。

**实测**：单发 `write` 基本不变（**设计如此** —— 响应仍要等落盘才发）；
4 并发写 34 → 28 ms（1000 档）、104 → 91 ms（3000 档），串行因子 0.59 → 0.47。

**为什么收益有限**：1000 人档 db.json 只有 0.51 MB，写盘本身才十几毫秒。
这条是**为库变大准备的**：写一次要写 `.tmp` + 复制 `.bak` + rename ≈ **3 倍文件大小的 IO**，
库涨到十几 MB 时它才会成为主导。

---

## 5. 容量结论与阈值

* **千人社团（0.5 MB 库）**：列表 30 ms 级、写 30 ms 级、4 并发登录 0.9 s —— 单机单进程完全够用。
* **增长曲线**：成员/任务每 ×3，单发耗时涨 ~1.3–1.6×（写盘与序列化是线性的）。
* **建议的重新设计阈值**：`db.json > 20 MB`，或日均写请求达到数千次 ——
  届时"每次写都重写全库"会成为主导，应该换成真正的数据库。
  > ⚠ **这条建议 2026-09-20 已落地，但路线与当时设想的不同**：club-server 的持久化已换成
  > **MySQL/MariaDB**（`server/src/mysql_store.cj`：一个事务里只 REPLACE 变化行 + 显式 DELETE，
  > **不再整库重写**；文件后端只作为**代码路径**存在，供单测与运维台构建使用），见
  > `docs/mysql-backend.md` §十二。上面那句"等 CangDB 有相容版本"**不再是路线** —— 实际走的是
  > 轻舟 `db_mysql.cj` + 内置 `third_party/mariadb-driver`；`fw_rbac_store.cj` / `fw_rbac.cj`
  > 是**运维台 RBAC** 的文件适配层，与 club-server 的库无关。
  > 本节其余数字（`db.json` 体积、整库重写的 3× IO）都是**文件后端时代**的实测基线，保留作对照。
* **已确认不是瓶颈的**：列表排序（已是 O(n log n)）、令牌表（已回收）。

---

## 6. 本基准**没有**覆盖的（老实交代）

1. **`/plans` 的树深度排序键** —— 键闭包走父链，是动作 1 最该被验证的地方，目前无数据。
2. **并发规模只有 4**，没有做吞吐量、长稳、内存增长测试。
3. **单机单进程、本机 SSD、Windows、无网络延迟**；不代表跨网/容器/机械盘。
4. **启动就绪**含进程启动与首个 `/health`，有 ±30 ms 抖动（见过一次 604 ms 离群值）。
5. **早期临时脚本量到的"3000 成员时 `/tasks` 1017 ms"无法被本脚本复现** ——
   该数字**作废**，此前若在别处引用过，以本文件为准。

---

## 7. 回归方法（改完性能相关代码后照做）

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
.\build\club-server.exe test
.\build\club-server.exe test "mysql://root:<口令>@127.0.0.1:3307/club_test"   # 带 DSN 才会跑 MySQL 往返（含 4 字节字符与反斜杠两条回归闸门）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tls-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1        # 需要时再对比 worktree 旧版
```

**当轮基线（2026-09-15，即容量改造那一轮）：单测 349 / 冒烟 347 / TLS 22，全绿。**
（之后第四轮复验又修了 6 条，**当时**为 387 / 360 / 22 —— 最新数字与跑法见 `README.md` 顶部。
**2026-10-04 复测**：单测不给 DSN `PASS 510 / FAIL 0`、给 DSN `PASS 562 / FAIL 0`；冒烟 440 / 0；
客户端契约 33 / 0；后台 38 / 0；运维页 82 / 0。`tests/tls-check.ps1` 是 **PASS 4 / FAIL 3** ——
那是**预先存在的环境问题**（`server/certs` 未入库、本机副本是 2026-09-17 的），**不要按"全绿"读**。）

性能改动的纪律：

1. 结论必须来自**同一个脚本、同一种数据形状**的前后对比；
2. 只报中位数，并注明噪声带（本机 ±15 ms）；
3. 收益在噪声带内的改动，就老实说"没测出收益，价值是最坏情况下界"，不要包装成优化成绩。

---

## 附：本轮涉及的代码

| 文件 | 改动 |
| --- | --- |
| `server/src/store.cj` | 堆排序（`sortByKey`/`siftDown`）；`Snapshot` 两段式落盘；`flushPending` / `snapshotFlush` 中间件 |
| `server/src/auth.cj` | `pruneTokens`（动作 3） |
| `server/src/h_auth.cj`、`h_secret.cj` | 注册 / 登录 / 改密 / 重置密码改三阶段加锁（动作 2） |
| `server/src/main.cj` | 挂 `snapshotFlush`；`init-admin` 走同步落盘 `storeSaveNow` |
| `server/src/tests.cj` | `testDeferredSave` / `testTokenPrune` / `testSortEdge`（+27 断言） |
| `server/tests/bench.ps1` | **新增**：可复现容量基准（含与历史版本对比的方法） |
