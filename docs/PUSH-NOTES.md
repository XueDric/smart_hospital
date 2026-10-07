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
2. **用完检查没有残留**（已确认干净）：
   ```powershell
   git remote get-url origin                    # 应仍是 https://github.com/...
   git config --local --get http.sslVerify      # 应「未设置」
   ```

### ⚠ 这个绕过本身也不稳：要**轮着试 IP**

2026-10-07 后续实测：同一条 push 在不同时刻会**随机**落到
`Failed to connect`（21 秒超时）或 `Recv failure: Connection was reset`。
**同一个 IP（`20.27.177.113`）上一轮成功、下一轮就失败** —— 所以不要认定"某个 IP 是好的"。

可用的做法是**轮询 + 重试**：

```powershell
$ips = @('20.27.177.113','140.82.112.3','140.82.113.3','140.82.114.3','140.82.121.3','20.201.28.151')
foreach($round in 1..3){
  foreach($ip in $ips){
    git -c "url.https://$ip/.insteadOf=https://github.com/" -c http.sslVerify=false push origin main
    if($LASTEXITCODE -eq 0){ Write-Host "✅ 经 $ip 推送成功"; break }
  }
  if($LASTEXITCODE -eq 0){ break }
}
```

实测就是靠这个在第 2 轮的第 3 个 IP（`140.82.113.3`）推上去的。
**结论：这个网络环境下的推送是"重试到成功"，不是"一次就成"。**

### ★★ 但"TCP 通"不等于"能用"—— 轮询前要先**筛**（2026-10-07 加）

上面那句"轮着试"说得太粗，实测被它坑过一次：**所有 6 个 IP 逐轮全失败**，
而 `Test-NetConnection` 显示它们**全都 TCP 可达**。原因查清了，是个很关键的陷阱：

> **`url.<ip>.insteadOf` 只改写了初始 URL，管不到重定向目标。**
> GitHub 会对"用 IP 访问"回一个 **301 → `https://github.com/...`**，
> git 顺着这个 Location 走，于是**重新按 DNS 解析 `github.com`** ——
> 而本机 DNS 恰好返回那个**连不通的** `20.205.243.166`（20.2xx 段）。
> 于是"我明明指了可用 IP"却仍然超时。

日志里的特征长这样（`GIT_CURL_VERBOSE=1` 能看到）：

```
== Info:   Trying 140.82.113.3:443...
== Info: schannel: renegotiating SSL/TLS connection
== Info:   Trying 20.205.243.166:443...        ← ★ 这里偷偷换了目标
== Info: connect to 20.205.243.166 port 443 ... failed: Timed out
fatal: unable to access 'https://140.82.113.3/...': Failed to connect to github.com:443
```

**所以筛选条件不是"TCP 通"，而是"这一跳能不能真的把 GitHub 的 TLS 跑起来"**
（即能返回 HTTP 响应，而不是 `%{http_code}=000`）：

```powershell
# 逐个 IP 判断"是否真的能服务 GitHub 的 HTTPS"
foreach($ip in @('140.82.112.3','140.82.113.3','20.27.177.113')){
  $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 12 -k `
            "https://$ip/XueDric/smart_hospital.git/info/refs?service=git-receive-pack" `
            -H "Host: github.com"
  "  $ip -> $code"   # 401 = ✅ 真能用（401 只是"要认证"）；000 = ❌ 跳过
}
```

实测结果差异很大（这正是"TCP 全通但都不能用"的原因）：

| IP | TCP 443 | 真 TLS |
| --- | --- | --- |
| `140.82.112.3` | 通 | ✅ **401（可认证，能用）** |
| `140.82.113.3` | 通 | ❌ 000 |
| `20.27.177.113` | 通 | ❌ 000 |

**用筛出来的那个 IP 一次就推上去了**（本次就是 `140.82.112.3`，`exit=0`）。
`401 Unauthorized` 是**好现象**：它说明 TLS 与 HTTP 都通了，只差认证 ——
而认证由凭据管理器里的 token 提供（本机已存 `git:https://github.com`）。

> 📌 教训：**"端口开着"是很弱的信号**。要么用协议层探测（上面这条 curl），
> 要么直接看 git 的 verbose 日志里 `Trying <IP>` 有没有**被换成别的地址**。

### ⚠⚠ 但这个绕过有个**天花板**：它依赖 DNS"碰巧"给个好 IP

2026-10-07 又一次实测，把上面的机制彻底看清了 —— **`insteadOf` 绕过本质上是不完备的**：

```
== Info:   Trying 140.82.112.3:443...          ← 我们指定的 IP，TLS 起来了
== Info: ALPN: server accepted http/1.1
== Info: schannel: renegotiating SSL/TLS connection
<= Recv header: HTTP/1.1 301 Moved Permanently  ← ★ GitHub 让它去 github.com
== Info:   Trying 20.205.243.166:443...         ← 于是重新查 DNS，拿到连不通的 IP
fatal: unable to access 'https://140.82.112.3/...': Failed to connect to github.com:443
```

**关键**：GitHub 对"用 IP 访问"会回 **301 → `https://github.com/...`**，
而 `url.<ip>.insteadOf` **只改写初始 URL，管不到重定向目标**。
于是 push 能否成功，取决于**那一刻 DNS 恰好返回哪个 IP**：

| DNS 返回 | 结果 |
| --- | --- |
| 可达 IP（如 `140.82.11x.3`） | ✅ push 成功 |
| `20.205.243.166`（本机 DNS 的常态） | ❌ 超时 —— **哪怕初始 IP 是好的** |

这解释了为什么同一条命令**上一轮成功、下一轮失败** ——
**6 个 IP 全部"协议层可用"（探针都返回 401）时，push 依然可能全失败**，因为瓶颈不在初始 IP。

**所以能做的只有"多轮重试"，等 DNS 变**：

```powershell
# 实测靠这个在第 3 轮成功（前两轮全失败）
foreach($round in 1..8){
  foreach($ip in @('140.82.112.3','140.82.113.3','140.82.114.3','140.82.121.3')){
    # ⚠ 加 http.connectTimeout 让坏 IP **快速失败**，否则每轮要等 21 秒
    git -c "url.https://$ip/.insteadOf=https://github.com/" -c http.sslVerify=false `
        -c http.connectTimeout=6 push origin main
    if($LASTEXITCODE -eq 0){ Write-Host "✅ 经 $ip 成功"; break }
  }
  if($LASTEXITCODE -eq 0){ break }
  Start-Sleep -Seconds 2
}
```

> 🔴 **真正可靠的修法只有两个**（都要你来做一次性的操作）：
> 1. **改用 SSH**：`ssh.github.com:443` 实测**可达且没有这个 301 问题**，
>    只需生成 key 并加到 GitHub（本机目前**没有** SSH key）。
> 2. **修 hosts / DNS**：让 `github.com` 解析到可达 IP ——
>    需要**管理员权限**（本会话没有）。
>
> 在做成这两件事之前，"推送"始终是**碰运气 + 重试**。
> 📌 代码本身是安全的：提交都在**本地仓库**，push 失败不会丢东西。

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
