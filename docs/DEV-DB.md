# 仓库自管的开发数据库（devdb）

> **为什么要有它**：原来本项目借用社团那台便携 MariaDB（端口 **3307**、库 `hospital`），
> 结果两边混在一起、权限也受社团的 root 口令牵制（本项目账号**没有建库权限**，
> 补测试库时卡住）。现在本仓库自带一套，**与社团完全隔离**。

---

## 一、规格

| 项 | 值 |
| --- | --- |
| 端口 | **3317**（社团那台是 3307，互不干扰） |
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
# 客户端（本机便携包，与社团那台共用同一套二进制）
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

---

## 五、为什么不用社团那台（历史原因，留档）

1. **权限**：本项目账号 `hospital` 在社团那台上**没有 CREATE DATABASE**，
   而测试库是跑 `accept` 的前提（`accept` 会清空业务表，所以只允许跑在显式测试库上）。
   补权限要 root，而社团那台的 **root 口令未知**。
2. **隔离**：社团那台的数据目录里是社团的库，混用容易误操作。
3. **可复现**：自管实例的端口/口令/库名都写在本文件里，换机器照着做就行。

> 补充：社团那台仍在 3307 跑着（`club_*` 库），**本项目不再依赖它**。
> 若你确要用它，把 `-Dsn` 换成 3307 那套即可 —— 脚本不写死端口。

---

## 六、重置

```powershell
.\devdb.ps1 stop
Remove-Item -Recurse -Force .\devdb\data
.\devdb.ps1 start     # 重新初始化空的实例
```

⚠ `Remove-Item` 前先确认路径是 `server\devdb\data`（本脚本的 `stop` 会先停服务）。
