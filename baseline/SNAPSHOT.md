# baseline/ —— cangjie_web 只读参考基线

> **这不是本项目的代码，是参考快照（reference snapshot）。**
> 本目录逐字节复制自 `cangjie_web` 工作区，**不带 `.git`**，**请勿在此目录内直接开发**。
>
> ⚠️ 同目录下的 `README.md` 是**原始**社团管理工具 README（属于快照内容，未改动）。
> 本文件（`SNAPSHOT.md`）是复制操作生成的**基线说明**，不属于原仓库。

| 项 | 值 |
| --- | --- |
| 来源工作区 | `E:\harmonyOS\cangjie_web` |
| 基线提交 | **`07a0922`** —— `docs: 文档一致性清扫 —— 现行基线数字与接口计数跟上代码` |
| `smart-hospital-project-brief.md` 记载的基线 | `07a0922` ✅ **一致** |
| 复制时工作区状态 | `git status --short` **为空**（无未提交改动，快照即提交态） |
| 当前目录内实际 | **352 个文件 / 7.53 MB**（含本说明文件） |
| 复制时曾带入 | 375 个文件 / 8.26 MB —— 上传前剔除了 25 个机密/外部文件，见「§二·补」 |
| 原工作区文件数 | 1247 个（其中 **871 个被排除**，见 §三） |

---

## 一、为什么放在 `baseline/` 而不是平铺到根

按 fork 决策（`smart-hospital-project-brief.md` §10 **Q1**），本仓库**不是**直接 fork `cangjie_web`，
而是「新建工作区 + 选择性搬运」。因此：

- 本目录是**素材库 / 模板来源**，供 P0 阶段「砍社团域 → 建科室/医生/排班/挂号单/病历」时取用；
- 本仓库根的「智慧医院」代码将来是**新写**的，不在这里就地改；
- ⚠️ **副作用：所有相对链接多了一层 `baseline/`**，修复对照见 §四。

---

## 二、复制范围（保留）

| 目录 / 文件 | 文件数 | 说明 | 复用度 |
| --- | --- | --- | --- |
| `server/third_party/qingzhou/` | 123 | 轻舟框架快照 v0.12.0 —— **不可重写，必须复用**。含 SSE（`context.cj`）、出站流式（`httpclient.cj`）、DB 抽象（`db.cj`/`dbquery.cj`） | ⭐⭐⭐⭐⭐ |
| `server/src/` | 38 | 服务端仓颉源码 33 个 `.cj` + `ops/`。**AI 编排（`ai_*.cj`）是最值钱资产**；`h_task`/`h_plan`/`h_member` 等社团 handler 仅作**写法模板** | ⭐⭐⭐⭐⭐ |
| `entry/` | 92 | 鸿蒙 ArkTS 客户端（21 页面 + `api/` + 7 状态仓 + `components/` + `Theme.ets`） | ⭐⭐⭐⭐ |
| `server/tests/` | 13 | 7 套测试脚本（`smoke.ps1` 440 项 / `bench.ps1` / `tls-check.ps1` / `client-contract-check.ps1` / `admin-check.ps1` / `ops-check.ps1` / `ai-*` + `ai-stub.mjs`） | ⭐⭐⭐⭐ |
| `docs/` | 29 | 全部中文文档（含 `README.md` 文档导航、`API-NOTES.md` 45 条踩坑、`code-review.md` 六轮评审） | ⭐⭐⭐⭐⭐ |
| `server/admin-web/` | 17 | Vue 3 管理端源码 + **随仓库提交的 `dist`** —— 运营看板可沿用 | ⭐⭐⭐ |
| `server/` 根脚本 | — | `build.ps1`（按版本探测 SDK：cjc 1.2.0 + stdx 1.1.3.1，校验 `MANIFEST.sha256`）等 6 个 `.ps1`/`.cmd` | ⭐⭐⭐⭐ |
| `AppScope/` `hvigor/` `scripts/` `assets/` `spike/` | 30 | 客户端脚手架、构建脚本与早期验证件 | ⭐⭐ |
| 根构建配置 | 8 | `build-profile.json5` / `oh-package.json5` / `hvigorfile.ts` / `code-linter.json5` / `.gitignore` / `.gitattributes` / `oh-package-lock.json5` / `local.properties` | ⭐⭐⭐⭐ |
| 根 `README.md` | 1 | 社团管理工具 README（含未决事项 #12、已知缺陷 S-14）——**关键证据来源** | ⭐⭐⭐⭐⭐ |

---

## 二·补、⚠ 复制后剔除的机密材料（2026-10-07 上传前审计）

这次复制用的是 `Copy-Item`，**绕过了源仓库的 `.gitignore`** —— 于是把三类
**源仓库 `cangjie_web` 自己都未入库**的敏感物带了进来。上传 GitCode 前已剔除：

| 剔除项 | 文件数 | 源仓库 `.gitignore` 的原话 |
| --- | --- | --- |
| `baseline/signing/` | 9 | 「`.p12` 一旦提交就等于泄露；`.cer`/`.p7b` 按 AppGallery 规则也不得转发」（`Xue_Dric.p12` 签名私钥 + 调试证书） |
| `baseline/server/certs/` | 2 | 「证书与私钥（自签证书的 `key.pem` 是机密）」（`key.pem` 是 **TLS 私钥**） |
| `baseline/_fetch/` | 14 | 「赛道官方页面快照 / 章程 PDF…原始文件留在本机即可，不进版本库」 |

**另外**：`baseline/docs/mysql-backend.md:358` 里有一条**明文局域网开发口令**
（`club` 账号），已就地脱敏为 `<REDACTED-本地开发口令>`。该口令的原件仍在
`cangjie_web` 与 `E:\cangjie\mariadb\LAN-CREDS.txt`，本仓库不再持有。

> 原件全部仍在 `E:\harmonyOS\cangjie_web`，未做任何删除，可随时按需取回。
> 新仓库 `.gitignore` 已同时加上**目录级 + 扩展名级**两层兜底（`*.pem` `*.p12` `*.pfx`
> `*.jks` `*.keystore` `*.csr` `*.cer` `*.crt` `*.p7b` `*.p10`），防止将来有人把材料放到别处。

---

## 三、未复制（排除清单 —— 871 个文件）

| 排除项 | 文件数 | 体积 | 排除理由 |
| --- | --- | --- | --- |
| `entry/build/` | 381 | 19.69 MB | 客户端构建产物，可重新生成 |
| `server/build/` | 77 | 44.83 MB | 服务端构建产物（exe/DLL），可重新生成 |
| `.hvigor/` | 25 | 4.50 MB | hvigor 构建缓存 |
| `oh_modules/` | 79 | 0.33 MB | OHPM 依赖缓存，`ohpm install` 可还原 |
| `.git/` | — | — | **按决策不 fork 历史**（218 次提交属社团域） |
| `.idea/` `.cxx/` `node_modules/` | — | — | IDE / 工具缓存 |
| `社团管理工具-1.0.0-1000000-release.zip` | 1 | 2.44 MB | **按指示剔除**：社团域发布包，与智慧医院无关。原件仍在 `cangjie_web`，可随时取回 |

---

## 四、路径映射表（相对链接修复对照）

整目录移动导致所有相对链接多一层 `baseline/`。规则只有两条：

| 原链接写法（相对 `smart-hospital-project-brief.md`） | 移动到 `baseline/` 后 | 示例 |
| --- | --- | --- |
| `../server/...`、`../entry/...`、`../README.md` | `baseline/server/...`、`baseline/entry/...`、`baseline/README.md` | `../server/src/ai_tools.cj#L54` → `baseline/server/src/ai_tools.cj#L54` |
| `docs/x.md`、裸 `x.md` | `baseline/docs/x.md` | `capacity-baseline.md` → `baseline/docs/capacity-baseline.md` |

**行号锚点（`#L54`、`#L30-L37`）不受影响** —— 内容逐字节一致，行号保持有效 ✅

✅ **`baseline/docs/**` 内部链接无需修复 —— 已实测确认（2026-10-07 复核）**

初次搬运时曾担心「29 份文档互相引用的 488 处链接会断」。**实测结论：不成立，无需修**。

- `docs/` 是**整目录**一起搬进来的，内部文档互相引用的是**同目录裸文件名**（`README.md`、
  `llm-ops-guide.md`、`api-design.md` …），相对关系**完全没变**；
- 剥离代码围栏与行内代码后精确扫描：**真实 markdown 链接 31 条，断链 0 条**；
- `docs/README.md` 里那个「488 处引用」统计的是**全仓文件名文本提及**（含代码注释与
  `` `反引号` `` 包裹的裸文件名），**不是可点击链接** —— 当时把它误当成断链风险了。

> 📌 另注：`baseline/docs/**` 中还有大量 **`server/...` / `entry/...` 反引号文本提及**，
> 那是**未来智慧医院代码应有的路径**，不是断链；P0 建出真实 `server/` 后自动"成立"。

---

## 五、复用时必须知道的 5 条硬骨头

直接来自 `smart-hospital-project-brief.md` §5，落在本目录的具体位置：

| # | 结论 | 本目录证据 |
| --- | --- | --- |
| 1 | **号源/挂号必须脱离内存 Store**（唯一架构级决策） | `server/src/mysql_store.cj:30-37` 整体替换语义 · `server/third_party/qingzhou/src/db.cj:104` `exec()` 返回受影响行数 · `db.cj:152` `withTransaction` |
| 2 | **分诊结论必须非流式 + 校验后返回**（预问诊文本才可流式） | `server/src/ai_client.cj:15-20` 三条设计口径 · `server/third_party/qingzhou/src/context.cj:301/314` 流式 API |
| 3 | **AI 配置从命令行改 DB 驱动，但密钥不落库** | `server/src/ai_config.cj:75/321/325` |
| 4 | **挂号绝不能进离线队列** | `entry/src/main/ets/api/AiApi.ets:3` 已立的红线 |
| 5 | **RAG 是全新模块，无现成库**（全仓 0 匹配） | 本目录内同样 0 匹配，需新写 |

---

## 六、原始上下文入口

接手时**先读**（按推荐顺序）：

1. `../smart-hospital-project-brief.md` —— 项目启动说明，唯一上下文入口
2. `docs/README.md` —— 原仓库 29 份文档的中文导航（按「我要做什么」查）
3. `docs/HANDOFF.md` —— 原项目交接说明
4. `docs/API-NOTES.md` —— 编译期 API 事实 + 45 条踩坑（写仓颉前必读）
5. `README.md`（本目录）—— 未决事项 #12、已知缺陷 S-14

---

*本文件由复制操作一并生成，不属于 `cangjie_web` 原始内容。*
