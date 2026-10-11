# Git 推送操作步骤（新分支 + PR 链接）

> **背景**：本机 `E:\smart_hospital` 目前**不是 git 仓库**，且 **GitHub 网络不稳定**（见 [`PUSH-NOTES.md`](PUSH-NOTES.md)）。
> 本文给两条可选路径。**路径 A（就地建仓）不依赖网络，最稳**；路径 B 需网络窗口可用。

---

## 路径 A（推荐）：就地 `git init` + 接远端

> 前提：先确认本地多出的内容（`frontend-interactive/`、`outputs/`、`.workbuddy-ai/`）确实要进版本库；
> `outputs/` 与 `.workbuddy-ai/` 现已由 `.gitignore` 排除，不会入库。

```bash
cd /e/smart_hospital

# ① 建仓 + 主分支定名
git init -b main

# ② 接远端（克隆用 HTTPS；推送走 §5 的代理）
git remote add origin https://github.com/XueDric/smart_hospital.git

# ③ 先看将被纳入的文件（确认 outputs/ 与 .workbuddy-ai/ 不在列表中）
git add -A
git status --short | head -40
git ls-files | grep -E '^(outputs/|\.workbuddy-ai/)' && echo "⚠ 未被正确忽略！" || echo "✅ outputs/ 与 .workbuddy-ai/ 已被忽略"

# ④ 建立新分支并提交
git switch -c chore/gitignore-outputs-workbuddy
git commit -m "chore: ignore outputs/ and .workbuddy-ai/

- outputs/：本机运行产物（截图/测试 JSON/打包 zip/预览 HTML），可由脚本重新生成
- .workbuddy-ai/：工具工作区状态（memory/），属本机态，不入版本库"

# ⑤ 推送（需网络窗口；走本机 CONNECT 代理，见 §5）
git -c http.proxy=http://127.0.0.1:8445 -c http.connectTimeout=10 push -u origin chore/gitignore-outputs-workbuddy
```

> ⚠ **就地 init 的首推风险**：本地与远端可能内容不一致，`git push` 会被拒（non-fast-forward）。
> 处理：先 `git fetch origin`，再 `git rebase origin/main`（或按需 `--allow-unrelated-histories` 合并）后再推。
> **更干净的做法**是先路径 B 克隆，把本地多出的内容按需拷进去。

---

## 路径 B：克隆远端后在其上操作

```bash
# ① 起代理（GH_IPS 用 gh-pick.mjs 挑出的可用 IP）
GH_IPS=<可用IP> node "$TEMP/gh-connect-proxy.mjs" 8445

# ② 克隆
git -c http.proxy=http://127.0.0.1:8445 clone https://github.com/XueDric/smart_hospital.git sh_remote
cd sh_remote

# ③ 应用 .gitignore 变更（把本地改好的 .gitignore 拷进来）
cp /e/smart_hospital/.gitignore .

# ④ 建分支 + 提交 + 推送
git switch -c chore/gitignore-outputs-workbuddy
git add .gitignore
git commit -m "chore: ignore outputs/ and .workbuddy-ai/"
git -c http.proxy=http://127.0.0.1:8445 push -u origin chore/gitignore-outputs-workbuddy
```

---

## 第 3 项（从索引移除）命令模板

**当前工作区无索引，此项不适用。** 若将来某次已把这两个目录提交进了历史，用下面命令从索引移除并**保留本地工作副本**：

```bash
# -r 递归；--cached 只动索引、不动工作区文件（关键！）
git rm -r --cached outputs/
git rm -r --cached .workbuddy-ai/

# 若提示 "pathspec did not match"（说明只是被 ignore、从未入库），属正常，无需处理

# 验证：索引里应查不到它们，但本地文件仍在
git status --short
git ls-files | grep -E '^(outputs/|\.workbuddy-ai/)' || echo "✅ 索引中已无这两个目录"
ls -d outputs .workbuddy-ai && echo "✅ 本地副本仍在"

git commit -m "chore: stop tracking outputs/ and .workbuddy-ai/"
```

> ⚠ **切勿**用 `git rm -r outputs/`（不加 `--cached`）—— 那会**连本地文件一起删掉**。

---

## 第 4 项：PR 创建链接

### GitHub（本仓库托管平台）

推送成功后，GitHub 会在 push 输出里直接打印创建链接：

```bash
git push -u origin <分支名>
# 输出末尾会给出：
#   remote: Create a pull request for '<分支名>' on GitHub by visiting:
#   remote:   https://github.com/XueDric/smart_hospital/pull/new/<分支名>
```

**链接格式**：

```
https://github.com/<owner>/<repo>/pull/new/<branch>
```

按本仓库代入即：

```
https://github.com/XueDric/smart_hospital/pull/new/chore/gitignore-outputs-workbuddy
```

> 若想带**预填标题**，可用 query 参数（需 URL 编码）：
> ```
> https://github.com/XueDric/smart_hospital/compare/main...chore/gitignore-outputs-workbuddy?expand=1&title=chore%3A+ignore+outputs%2F+and+.workbuddy-ai%2F
> ```

### 其他托管平台的链接格式（备查）

| 平台 | 新 PR 链接格式 |
| --- | --- |
| GitHub | `https://github.com/<owner>/<repo>/pull/new/<branch>` |
| GitLab | `https://gitlab.com/<owner>/<repo>/-/merge_requests/new?merge_request[source_branch]=<branch>` |
| Gitee | `https://gitee.com/<owner>/<repo>/compare/<base>...<branch>` |
| Bitbucket | `https://bitbucket.org/<owner>/<repo>/pull-requests/new?source=<branch>` |

> 也可以用 `gh` CLI 一步到位（若已登录）：
> ```bash
> gh pr create --base main --head chore/gitignore-outputs-workbuddy \
>   --title "chore: ignore outputs/ and .workbuddy-ai/" \
>   --body "补充 .gitignore：忽略本机运行产物与工具工作区状态。"
> ```
