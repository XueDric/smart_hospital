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

---

## 5. ★ 2026-10-11：改用**本机 CONNECT 代理**，一次成功（推荐做法）

§2 的 `url.<ip>.insteadOf` 绕不过 301（见 §2 末尾那两段），所以这一次不再跟 DNS 赌运气，
而是**在本机起一个只做 `CONNECT` 转发的 TCP 代理**，把 git 的代理指到它：

- git 仍然访问 `https://github.com/...` ⇒ **Host 头与 TLS SNI 都是 `github.com`**，
  所以 GitHub **不会**回 301，证书也能正常校验（**不再需要 `http.sslVerify=false`**）；
- 代理内部对**候选 IP 并发抢连**，谁先连上就用谁 ⇒ 把"逐次抽签"的可达性问题一次性吃掉；
- 只监听 `127.0.0.1`，只转发到 GitHub 的 443，**不改任何 git 持久配置**。

### 5.1 代理脚本

存成任意位置（例：`%TEMP%\gh-connect-proxy.mjs`），`node gh-connect-proxy.mjs 8445 [日志文件]`：

```js
// 本机 CONNECT 代理：把 git 的 HTTPS 流量转到可达的 GitHub IP。
// Host/SNI 仍是 github.com（不触发 301）；对候选 IP 并发抢连（可达性是逐次抽签的）。
import net from 'node:net';
import fs from 'node:fs';

const LISTEN_PORT = Number(process.argv[2] || 8445);
const LOG = process.argv[3] || '';
const TARGET_PORT = 443;
const CANDIDATES = ['20.205.243.166', '20.27.177.113', '140.82.112.3', '140.82.113.3',
                    '140.82.114.4', '140.82.116.3', '4.237.22.38', '20.200.245.247'];

const log = (m) => { const l = `${new Date().toISOString()} ${m}\n`;
  if (LOG) { try { fs.appendFileSync(LOG, l); } catch {} } process.stdout.write(l); };

function connectAny(timeoutMs) {
  return new Promise((resolve, reject) => {
    const socks = []; let settled = false; let pending = CANDIDATES.length;
    for (const ip of CANDIDATES) {
      const s = net.connect({ port: TARGET_PORT, host: ip });
      socks.push(s); s.setTimeout(timeoutMs);
      s.on('connect', () => { if (settled) { s.destroy(); return; } settled = true;
        for (const o of socks) if (o !== s) o.destroy(); log(`upstream picked ${ip}`); resolve(s); });
      const fail = (why) => { s.destroy(); if (settled) return;
        if (--pending === 0) { settled = true; reject(new Error(`all candidates failed (${why})`)); } };
      s.on('timeout', () => fail('timeout'));
      s.on('error', (e) => fail(e.code || e.message));
    }
  });
}

net.createServer((client) => {
  client.setNoDelay(true);
  let handled = false;
  const onFirst = (buf) => {
    if (handled) return; handled = true;
    const head = buf.toString('latin1');
    log(`first chunk: ${JSON.stringify(head.split('\r\n')[0])}`);
    if (!/^CONNECT /i.test(head)) { client.end('HTTP/1.1 405 Method Not Allowed\r\n\r\n'); return; }
    const split = head.indexOf('\r\n\r\n');
    connectAny(5000).then((up) => {
      up.setNoDelay(true);
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (split >= 0) { const rest = buf.subarray(split + 4); if (rest.length) up.write(rest); }
      client.removeListener('data', onFirst);
      client.pipe(up); up.pipe(client);
      up.on('error', () => client.destroy());
      up.on('close', () => client.destroy());
    }).catch((e) => { log(`connect failed: ${e.message}`); client.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); });
  };
  client.on('data', onFirst);
  client.on('error', (e) => log(`client error ${e.code || ''}`));
}).listen(LISTEN_PORT, '127.0.0.1', () => log(`listening 127.0.0.1:${LISTEN_PORT}`));
```

### 5.2 用法（三步，实测有效）

```powershell
# ① 起代理（后台；日志落到 %TEMP%\gh-proxy.log）
Start-Process node -ArgumentList "$env:TEMP\gh-connect-proxy.mjs","8445","$env:TEMP\gh-proxy.log" -WindowStyle Hidden

# ② 先确认这一跳真能用（期望 code=200；若为 000 就重启代理换一批 IP）
curl.exe -sS -o NUL -w "code=%{http_code}`n" --max-time 30 -x http://127.0.0.1:8445 https://github.com/

# ③ 走代理推送 / 拉取（只作用于这一条命令，不写进配置）
git -c http.proxy=http://127.0.0.1:8445 -c http.connectTimeout=10 push origin main
git -c http.proxy=http://127.0.0.1:8445 ls-remote --heads origin   # 只读自检，成功时打印远端 main 的 sha
```

**2026-10-11 实测**：`curl -x` → `code=200`；`ls-remote` → `exit=0`，
打印 `be569cd026ceabc5274c523457c4e06854d98567  refs/heads/main`（当时 `origin/main`）。
代理日志显示抢连选中 `20.27.177.113:443`（而 `140.82.113.3` 在同一时刻 `ETIMEDOUT` ——
**再次说明"某个 IP 好不好"是逐次抽签，不要再把 §1/§2 的表当固定结论**）。

> 📌 与前几版的差别：**不需要 `http.sslVerify=false`**（SNI 仍是 github.com，证书正常），
> 也**不需要 `url.insteadOf`**（不产生 301）。push 完记得 `Stop-Process` 掉代理进程。
> §3 的两条"真正可靠的修法"（SSH / 修 hosts）仍然更长期 —— 但有了本节的代理，
> 在拿到管理员权限之前**不必再靠重试撞运气**。

### 5.3 ⚠ 同一天晚些时候：窗口会**整个关上**，"抢连成功"也不等于"能用"（2026-10-11 复盘）

§5.2 那次成功之后不到一小时，同一台机器、同一批 IP 出现了下面三种**连续的**失败形态
（全都记下来，免得下次又把它们当成"脚本坏了"）：

| 现象 | 日志/报错原文 | 说明 |
| --- | --- | --- |
| 抢连选中的 IP 连上又被对端关掉 | `git: fatal: unable to access ...: schannel: server closed abruptly (missing close_notify)`；代理日志 `upstream picked 4.237.22.38:443` → 6 秒后 `upstream close` | **TCP 连通 ≠ 能完成 TLS/HTTP 会话**。抢连只看"谁先连上"，选中的未必能服务请求 |
| 固定 IP 隧道也连不上 | `upstream error: connect ETIMEDOUT 20.27.177.113:443`（就是 §5.2 成功时选中的那个 IP） | 同一个 IP 十几分钟后不可达 ⇒ §1/§2 的 IP 表**确实不能当固定结论** |
| 所有候选 IP 一起失效 | 抢连版逐条回 `CONNECT tunnel failed, response 502`；TLS 级探测（下）9 个 IP **全部 TIMEOUT** | 这不是"换个 IP 就行"，而是**这一跳整体不通** —— 唯一办法是**等窗口**再重试 |

**更好的筛法：TLS 级探测（比 §2 的 curl 探针更贴近真实可用性）**

```javascript
// %TEMP%\gh-probe.mjs —— 对每个候选 IP 真做一次 TLS 握手 + 一次 info/refs 请求，报 HTTP 状态码
// 判据：HTTP 401 = 这一跳现在可用（能完成会话）；TIMEOUT / ERR / CLOSED = 现在不可用
import tls from 'node:tls';
const IPS = ['20.205.243.166','20.27.177.113','140.82.112.3','140.82.113.3',
             '140.82.114.3','140.82.114.4','140.82.116.3','4.237.22.38','20.200.245.247'];
const probe = (ip, ms) => new Promise((r) => {
  const t0 = Date.now(); const s = tls.connect({ host: ip, port: 443, servername: 'github.com', timeout: ms });
  let done = false; const fin = (v) => done || ((done = true), s.destroy(), r(`${ip}\t${v}\t${Date.now() - t0}ms`));
  s.on('secureConnect', () => s.write('GET /XueDric/smart_hospital.git/info/refs?service=git-receive-pack HTTP/1.1\r\nHost: github.com\r\nConnection: close\r\n\r\n'));
  let b = ''; s.on('data', (d) => { b += d.toString('latin1'); const m = b.match(/^HTTP\/1\.[01] (\d{3})/); if (m) fin(`HTTP ${m[1]}`); });
  s.on('timeout', () => fin('TIMEOUT')); s.on('error', (e) => fin(`ERR ${e.code || e.message}`)); s.on('close', () => fin('CLOSED'));
});
for (const r of await Promise.all(IPS.map((ip) => probe(ip, 8000)))) console.log(r);
```

```powershell
node "$env:TEMP\gh-probe.mjs"     # 有 HTTP 401 才值得起代理；全 TIMEOUT 就别折腾了，等一会儿
```

> 📌 结论：这套绕过**能用，但是"看天"**。可用窗口内一次成功；窗口关上时
> 任何 IP / 任何隧道写法都救不回来。此时正确做法是**停下来、过一段时间重试**，
> 而不是继续换 IP 或加 `sslVerify=false`（那两者都不会改变结果，只会浪费一轮）。
> 长期解法仍是 §3 的 SSH 或修 hosts/DNS。

### 5.4 ✅ 2026-10-11 14:13：把 §5.3 的"等窗口"固化成一个自动重试脚本（本次两连推成功）

§5.3 只说了"要等窗口"，但手动等很容易在坏窗口里白试。本次把它做成**先 TLS 级挑 IP、
再起单 IP 代理、失败就整轮重来**的循环，两次推送（`d0afd6d..f5c164e`、`f5c164e..4646e83`）
都成功。三个可复用的细节：

1. **挑 IP 用 TLS 级探测，判据是 `HTTP 401`**（§5.3 的 `gh-probe.mjs`；本次脚本 `%TEMP%\gh-pick.mjs`
   把候选列表写成参数，并只输出一行 `PICK <ip> <HTTP 401>` 或 `NONE`）。探测本身很快（~10s）。
2. **代理只用一个已验证的 IP**：把 §5.1 脚本里写死的 `CANDIDATES` 换成
   `const CANDIDATES = (process.env.GH_IPS || '').split(',')...`，用 `GH_IPS=<挑中的 ip>` 起进程。
   **不要**让抢连版（多 IP 竞争）去跑 push —— 它只看"谁先 TCP 连上"，选中的常常是
   "连得上但 TLS 被对端掐断"的那种（本次第 1 轮挑到 `140.82.121.3` 后 push 连续
   502 / `schannel: server closed abruptly`）。
3. **一轮失败就整轮重来**（重新挑 IP），间隔 40s，最多十几轮。本次时间线：
   第 1 轮 `140.82.121.3`（吹了）→ 第 2、3 轮 `NONE` → 第 4 轮 `20.27.177.113` **成功**。
   ⇒ "某个 IP 能用"的寿命只有几分钟，**别把它当常量写进配置**。

**顺带记两条本次新增的环境事实**（用于判断"是这一个 IP 坏了，还是整跳不通"）：

| 目标 | TCP 443 | TLS(SNI=github.com) 完成会话 |
| --- | --- | --- |
| `20.205.243.166`（`github.com` 自身） | ❌ 连不上 | ❌ |
| `20.205.243.160`（`ssh.github.com`） | ✅ | ❌ `ERR_SSL_WRONG_VERSION_NUMBER`（这个口是 **SSH**，不是 TLS —— SSH over 443 是通的，缺的只是本机 SSH key） |
| `20.205.243.165` / `.168`（codeload / api） | ✅ | ❌ TIMEOUT（TCP 握手成功 ≠ 会话可用） |
| `185.199.108-111.133`（raw / objects） | ✅ | ❌ TIMEOUT |

> ⚠ **临时 PowerShell 脚本里的中文必须 UTF-8 with BOM**：本次把重试脚本按无 BOM 写出，
> PS 5.1 按 ANSI 解析中文引号，直接报 `The string is missing the terminator: '`（脚本一句没跑）。
> 这与 `server/devdb.ps1` 头部记的是同一条铁律，写临时脚本时同样适用。
