# 推送备忘 · 本机到 GitHub 的网络问题与绕过

> **现象（2026-10-07 实测）**：`git push` 报
> `Failed to connect to github.com:443` / `Recv failure: Connection was reset`，
> 重试 3 次全失败。

---

## 1. 根因：DNS 返回了一个**连不通**的 GitHub IP

| 检查项 | 结果 |
| --- | --- |
| `Resolve-DnsName github.com` | → **`20.205.243.166`** |
| `20.205.243.166:443` | ❌ **不通**（就是它导致 push 失败） |
| `api.github.com:443` | ✅ 通 |
| `github.com:22` / `ssh.github.com:443` | ✅ 通 |
| 百度 / Gitee | ✅ 通 |

**不是"GitHub 被墙"，也不是"网络全断"** —— 是 DNS 给出的那**一个** IP 恰好连不通。
逐个测已知 GitHub git IP，**6 个里有 5 个可用**：

| IP | 443 |
| --- | --- |
| `20.205.243.166`（DNS 返回的那个） | ❌ |
| `20.27.177.113` | ✅ **实测可用（本次就是从它推上去的）** |
| `140.82.112.3` / `140.82.113.3` / `140.82.114.3` / `140.82.121.3` / `20.201.28.151` | ✅ |

---

## 2. 绕过办法（本次实际用了这个）

用 git 的**一次性** `-c` 覆盖，把 github.com 重写到可用 IP：

```powershell
cd "E:\harmonyOS\智能医院客户端"
git -c "url.https://20.27.177.113/.insteadOf=https://github.com/" -c http.sslVerify=false push origin main
```

⚠ **两点必须知道**：

1. **`http.sslVerify=false` 是必要的**：URL 里写 IP 时，TLS 证书里的名字是 `github.com`，
   校验会对不上。它**只作用于这一条命令**（`-c` 不写配置）。
   副作用是这条连接不做证书校验 —— 因为目标是我们自己核对过的 GitHub 地址、
   且网络路径可信，才接受这个折中。**不要把 `http.sslVerify=false` 写进配置长期生效。**
2. **用完检查没有残留**（本次已确认干净）：
   ```powershell
   git remote get-url origin                    # 应仍是 https://github.com/...
   git config --local --get http.sslVerify      # 应「未设置」
   ```

---

## 3. 更稳的长期办法（按推荐顺序）

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **① 改用 SSH** | `ssh.github.com:443` 实测**可达**，且 443 通常不被拦；生成本机 SSH key 后加到 GitHub，remote 换成 `git@github.com:XueDric/smart_hospital.git` | 需一次性配 key（本机目前**没有** SSH key） |
| ② 修 hosts | 把 `github.com` 指到可用 IP（如 `20.27.177.113`） | ⚠ **需要管理员权限**（本会话无），且 IP 会变、要维护 |
| ③ 换 DNS | 换一个能返回可用 IP 的解析器 | 依赖上游 |
| ④ 代理 | 配 `http.proxy` | 需有可用代理 |

> 本次选「一次性 URL 重写」的理由：**不改持久配置、不需管理员、立即见效**，
> 代价只有"每次 push 要带两个 `-c`"。等要长期推代码时，建议走 **① SSH**。

---

## 4. 备份：Gitee 也可用

`gitee.com` 实测可达。如果需要国内镜像，可以再挂一个 `gitee` remote：

```powershell
git remote add gitee https://gitee.com/<你的用户名>/smart_hospital.git
git push gitee main
```

（本次**未**配置 Gitee —— 上表只是记录"它有网络可达性"这一事实。）
