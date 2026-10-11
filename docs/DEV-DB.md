# 仓库自管的开发数据库（devdb）

> **为什么要有它**：项目早期借用本机另一台便携 MariaDB（端口 **3307**、库 `hospital`），
> 结果数据混在一起、权限也受那台的 root 口令牵制（本项目账号**没有建库权限**，
> 补测试库时卡住）。现在本仓库自带一套，**与本机其它项目完全隔离**。

---

## 一、规格

| 项 | 值 |
| --- | --- |
| 端口 | **3317**（避开本机已有的 3307 实例，互不干扰） |
| **监听地址** | **`127.0.0.1`（仅回环）** —— 见下方"安全"一节 |
| 数据目录 | `server\devdb\data`（**不入库**，见 `.gitignore`） |
| 日志 | `server\devdb\mysqld.out.log` / `mysqld.err.log` |
| root 口令 | `devroot2026` |
| 业务账号 | `hospital` / `hospital_dev_2026` |
| 库 | `hospital`（开发）、`hospital_test`（**测试专用**，`accept` 只认它） |
| 版本 | MariaDB **11.4.13**（复用本机已有便携包，**不需要联网下载**） |

### ⚠ 安全：口令写在仓库里是可以的，**前提是它只绑回环**

本文件把 root 口令**明文写出来**，这是刻意的（本机隔离实例，便于照做）。
但它成立有个**硬前提**：`devdb.ps1` 启动时带 `--bind-address=127.0.0.1`。

- 实测过：**不带**这个参数时 mysqld 监听 `0.0.0.0:3317`，同局域网任何人都能连；
  当时只靠账号的 host 授权（`'hospital'@'localhost'`）兜着 ——
  那是**单层**防护，一旦有人补了 `@'%'` 账号就对外敞开。
- 绑回环是**结构性**隔离：网络层根本连不到，与"有哪些账号"无关。

> 自查：`Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3317`
> —— `LocalAddress` 必须是 `127.0.0.1`，**不该**是 `0.0.0.0`。

> ⚠ **绝不要**把这个实例暴露到公网。

---

## 二、一键启停

```powershell
cd server

# 启动（若数据目录不存在会先初始化）
.\devdb.ps1 start

# 看状态
.\devdb.ps1 status

# 停止
.\devdb.ps1 stop
```

首次初始化用 `.\devdb.ps1 init`（`start` 会自动检测并调用）。

---

## 三、连接

```powershell
# 客户端（本机便携包）
$cli = "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe"
& $cli -h 127.0.0.1 -P 3317 -u hospital "-phospital_dev_2026" --skip-ssl hospital_test
```

DSN（本项目统一格式）：

```
mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital       # 开发
mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test  # 测试（accept 用）
```

---

## 四、测试脚本怎么指向它

测试脚本的连接参数**全部从 `-Dsn` 派生**（见 `tests\common.ps1` 顶部说明）——
这是修过的一个真缺陷：原先 DSN 与 `-MySqlPort/-MySqlDb` 是**两份独立参数**，
很容易"服务端写 A 库、脚本查 B 库"，实测就踩了（断言一直读到空结果，
看起来像 SQL 坏了，其实是查错了库）。

```powershell
$dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# 建库（幂等）+ 建管理员（引导入口，口令只打印一次）
.\build\hospital-server.exe create-db    $dsn
.\build\hospital-server.exe create-admin $dsn

# 起服务
.\build\hospital-server.exe serve $dsn --port 8091

# 另开终端：跑测试（Dsn 一处改、处处一致）
$pw = "<上一步打印的管理员口令>"
.\tests\auth-check.ps1     -Base http://127.0.0.1:8091 -AdminPw $pw
.\tests\stress-booking.ps1 -Base http://127.0.0.1:8091 -Tokens 50 -ScheduleTotal 50 -Dsn $dsn -AdminPw $pw
```

### ⚠ 新建**第三个**库时，`create-db` 必须带 `--admin-dsn`

`hospital` 账号的实际授权是**按库逐个授**的（本机实测）：

```
GRANT CREATE ON *.*                          ← 全局：只能"建库"
GRANT ALL PRIVILEGES ON `hospital`.*         ← 库级：权限在这里
GRANT ALL PRIVILEGES ON `hospital_test`.*
```

所以**它能建出第三个库，却对新库没有任何权限**。`create-db` 现在会当场探测并告诉你：

```powershell
# ✅ 推荐：给一个有 GRANT OPTION 的 DSN，一步授好
$adm = "mysql://root:devroot2026@127.0.0.1:3317/"    # 管理员 DSN 可以不带库名
.\build\hospital-server.exe create-db mysql://hospital:hospital_dev_2026@127.0.0.1:3317/newdb_test --admin-dsn $adm

# 不给 --admin-dsn 时：它**明确失败**（exit=2），并打印出可复制的 GRANT 命令
```

> ⚠ **这一步不做，`check-db` / `accept` / `serve` 都会在 `migrateSchema` 的
> `ALTER` 上被拒**。原缺陷正是「`create-db` 报『库已就绪』、下一条命令才炸」——
> 失败被推迟，而且**报错的地方不是出错的地方**。现在 `create-db` **不会**再把
> "不可用"报成"就绪"。
>
> 📌 业务账号**不能**给自己授权，这是**正确**的安全设计（服务进程不该长期持有
> 授权能力）—— 所以正确做法是**显式提供**一个管理员 DSN（一次性使用），
> 而不是想办法让业务账号拿到 GRANT OPTION。

---

## 五、为什么不复用本机已有的 3307 实例（历史原因，留档）

1. **权限**：本项目账号 `hospital` 在那台上**没有 CREATE DATABASE**，
   而测试库是跑 `accept` 的前提（`accept` 会清空业务表，所以只允许跑在显式测试库上）。
   补权限要 root，而那台的 **root 口令未知**。
2. **隔离**：那台的数据目录里是**其它项目**的库，混用容易误操作。
3. **可复现**：自管实例的端口/口令/库名都写在本文件里，换机器照着做就行。

> 补充：那台仍在 3307 跑着，**本项目不再依赖它**。
> 若你确要用它，把 `-Dsn` 换成 3307 那套即可 —— 脚本不写死端口。

---

## 六、重置

```powershell
.\devdb.ps1 stop
Remove-Item -Recurse -Force .\devdb\data
.\devdb.ps1 start     # 重新初始化空的实例
```

⚠ `Remove-Item` 前先确认路径是 `server\devdb\data`（本脚本的 `stop` 会先停服务）。
