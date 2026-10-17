# 第三方依赖与外部服务审计

> 本文回答"**用了哪些开源组件、第三方模型、外部 API、数据集，以及各自许可证与合规边界**"，覆盖仓颉服务端、鸿蒙/安卓患者端、管理台网页。每条结论以仓库内文件为证据（`路径:行号`）；无证据处一律写"未找到"，不推测。

## 1. 服务端运行时依赖

### 1.1 轻舟 QingZhou（源码副本）

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 版本 / 出处 | 上游 v0.12.0 之后 HEAD（最近标签 v0.12.0），`gitcode.com/BIT-FSSLab/QingZhou`，commit `3d6c1a36…387b753` | `server/third_party/qingzhou/PROVENANCE.md:7-8`、`UPSTREAM_COMMIT:1` |
| 许可证 | **MIT**，Copyright (c) 2026 guowei, BIT FSSLab | `server/third_party/qingzhou/LICENSE:1-3`、`PROVENANCE.md:12` |
| 获取方式 | **使用副本**：vendored 源码快照，构建不读仓库外目录 | `PROVENANCE.md:3` |
| 工具链 / 改动 | 基线 cjc 1.2.0 + stdx 1.1.3.1；本地只改注释与文档措辞 | `PROVENANCE.md:10,14`、`README.md:9` |
| 完整性 | `MANIFEST.sha256` 仅为锚点，**构建期不校验**，需手工比对 | `PROVENANCE.md:11,23-24` |

⚠ 快照 `cjpm.toml:2-3` 仍写 `cjc-version="1.0.5"`、`version="0.1.0"`（过期元数据，版本口径以 PROVENANCE 为准）。⚠ 快照内含上游 Vue3 演示 `admin-web/`（vue ^3.4 / vue-router ^4.3 / vite ^5 / @vitejs/plugin-vue ^5，含 lock 与 dist），但**不参与本项目构建**（`server/build.ps1` 全文无 `admin-web`；`server/src/main.cj:203-220` 只挂 `server/admin-web`）。

### 1.2 MariaDB 驱动（源码副本，静态编译）

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 版本 / 出处 | `2.0.2`，`gitcode.com/Cangjie-SIG/mysql-driver.git`（Cangjie-SIG 组织仓），commit `f21a83ae…fb3fb6bd1` | `server/third_party/mariadb-driver/cjpm.toml:3`、`UPSTREAM_URL:1`、`UPSTREAM_COMMIT:1` |
| 许可证 | **Apache-2.0** | `LICENSE:1-2` |
| 获取方式 | 使用副本；`output-type=static`，因上游 cjpm 未声明 stdx，按 protocol→connection→cdbc 用 cjc 直编（需 Cangjie 1.2.0） | `cjpm.toml:5`、`server/build-mysql-driver.ps1:1,38,56,93-95` |
| 运行期外部依赖 | 需 OpenSSL 3 crypto 动态库 | `readme.md:46` |

⚠ `readme.md:5` 徽章仍写 v1.0.0，与 `cjpm.toml:3` 的 2.0.2 不一致（过期徽章）。

### 1.3 运行时二进制（Cangjie 运行时 / stdx / OpenSSL 3）

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 编译器 | cjc **1.2.0**（PATH 上的 1.1.3 触发 `LLVM ERROR: Broken module found`），不匹配即硬失败 | `server/build.ps1:4,31-33,102`、`server/README.md:17-20` |
| 标准库 | stdx **1.1.3.1**，静态链接 | `server/build.ps1:4`、`server/README.md:17-20` |
| OpenSSL 3 | 不入库；取序 `third_party/qingzhou/deps/openssl` → `-OpenSslDir` → Git for Windows `mingw64\bin`（实测 **3.5.7**） | `server/third_party/qingzhou/deps/openssl/README.md:1-3,12-19` |
| 产物 / 分发义务 | exe + `libcangjie-runtime.dll` + `libboundscheck.dll` + `libcrypto-3-x64.dll` + `libssl-3-x64.dll`；**部署包必须带这 4 个 DLL**，缺一即退出 1 | `deps/openssl/README.md:29-32`、`server/setup-runtime.ps1:3-5,71-103,132-135` |

⚠ 上述 DLL 随部署包分发，但仓库内**未找到任何许可证文件**，需上游确认（见第 9 节）。

### 1.4 数据库：MariaDB 11.4（便携版）

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 版本 | MariaDB **11.4.13** 便携版，复用本机已有包、不联网下载 | `docs/DEV-DB.md:20`、`server/devdb.ps1:73-76`、`server/README.md:20` |
| 生产口径 | **未在仓库内找到**生产 DB 版本建议（只有开发/测试口径） | `docs/DEV-DB.md` 全文 |
| 许可证 | 上游 MariaDB/MySQL 服务端 **GPLv2**；仓库内无许可证副本（便携版不入库） | 需上游确认 |

## 2. 鸿蒙端（ArkTS / Stage）

- **第三方 ohpm 包为零**：`dependencies`/`devDependencies` 均空对象（见 `oh-package.json5:2-4`、`hvigor/hvigor-config.json5:2-3`）；模块间只用本地包 `file:../common-core`，`registryType` 全为 `local`（见 `entry/oh-package-lock.json5`）。
- 构建插件 `@ohos/hvigor-ohos-plugin`（DevEco 自带，构建期）见 `hvigorfile.ts:1`；SDK 声明 `compatibleSdkVersion`/`targetSdkVersion = 5.0.0(12)`、`runtimeOS: HarmonyOS`（见 `build-profile.json5:8-10`）；各模块 `"license": "Apache-2.0"`。
- 系统 Kit（随 SDK 内置，非三方 OSS）：NetworkKit、AbilityKit、ArkData、CoreFileKit、ArkUI、PerformanceAnalysisKit（见 `common-core/src/main/ets/network/HttpClient.ets:1`、`storage/KeyValueStore.ets:1-2`、`storage/FileStore.ets:2`、`ui/ThemeManager.ets:1`、`entry/src/main/ets/entryability/EntryAbility.ets:1-2`）。
- 实测环境：DevEco Studio `DS-261.23567.138.36.2600821`、SDK `HarmonyOS 26.0.0`（API 26）、模拟器 Pura 90/API 24（见 `docs/FRONTEND-INTEGRATION.md:1775-1776`）。⚠ 与 `build-profile.json5:8` 的 `5.0.0(12)` 属不同口径，需人工确认实际编译基线。

## 3. 安卓端（android-patient）

- AGP **8.5.2** / Kotlin **2.0.21**（见 `android-patient/build.gradle.kts:2-3`）；Gradle **8.7** wrapper（见 `gradle/wrapper/gradle-wrapper.properties:3`）；三者均 Apache-2.0，由 Maven/Gradle 分发，不随仓库分发。
- compileSdk **35**、minSdk **26**、targetSdk **35**、Java/Kotlin target **17**（见 `app/build.gradle.kts:16,20-21,59-63`）；JDK 17（脚本接受 17–21，见 `android-patient/README.md:11-15`）。
- **三方运行时库为零**：`app/build.gradle.kts` 全文无 `dependencies {}`，`android.useAndroidX=false` ⇒ 无 AndroidX、无 Compose（见 `gradle.properties:2`）；源码只 import `android.*`/`java.*`/本项目包。

## 4. 管理台网页（server/admin-web）

**结论：零第三方前端依赖，纯手写 ES5/ES6 + `fetch`。**

- 无 npm/webpack/vite，资源全是普通 `<script>` 与本地 css（见 `server/admin-web/index.html:13-16,35,87-90`）。
- 无 CDN、无外域 `<script src>`/`<link>`；唯一外域字符串是占位文案 `https://dashscope.aliyuncs.com/compatible-mode/v1`，不被抓取（见 `js/pages.js:697`）；图标为自制 `favicon.svg`（1009 B，注释说明用 SVG 避免二进制小文件）。
- ⚠ `docs/ADMIN-WEB.md:16` 原称"仓里连 `package.json` 都没有"，与 1.1 节 qingzhou 快照内 Vue demo 的 `package.json` 冲突。**已修（2026-10-17）**：该处改为"`server/admin-web/` 内没有 `package.json`，也不参与 `build.ps1`；vendored 快照里另有一份上游 Vue3 演示，与本管理台无关"。

## 5. 外部 API 与第三方模型（AI 出站）

- 协议为 **OpenAI 兼容**：`/chat/completions` 与 `/embeddings`；provider 是自由文本，任何兼容端点（百炼 / DeepSeek / 自建）都能配（见 `server/src/ai_model.cj:92-97,307-341`、`server/src/ai_call.cj:268`）。
- 种子厂商 provider `"百练"`、base_url `https://dashscope.aliyuncs.com/compatible-mode/v1`（阿里云百炼）；默认对话 `qwen-plus`（温度 0.3、max_tokens 2048）、默认向量 `text-embedding-v3`（见 `ai_model.cj:92-97,778-804`）。
- 端点推导：基址或完整端点均可，CHAT 追加 `/chat/completions`、EMBEDDING 追加 `/embeddings`；**强制 `https://`**（见 `ai_model.cj:235-259,307-341`、`ai_call.cj:618`）。
- 超时 **30s**（1..300）、并发 **4**（1..64），信号量闸门；密钥只存 `env:名` / `file:路径` 引用；探活为 `aiProbeChat`/`aiProbeEmbedding`/`aiExtractEmbeddingDim`（见 `ai_settings.cj:174-183,442-443`、`ai_call.cj:282,302,423-457,682-745,757`）。
- **已定型结论：DeepSeek 无 embeddings 端点** —— `/embeddings` 与 `/v1/embeddings` 实测均 404，故向量路未端到端验证、关键词检索为默认路（见 `docs/P5-HANDOFF.md:13-18,20-29`、`README.md:58`、`docs/HISTORY-PROJECT-BRIEF.md:255-257`）；测试里出现 `deepseek-chat` 仅用于协议形状验证（`server/src/acceptance_ai.cj:164-166`）。
- 出站合规：仅发现主诉 + 科室名 + 提示词 + KB 片段，不含 patient_id；默认 `ai.enabled=0` 零出站；**未完成** DPA/留存删除、知情同意、脱敏预处理、出站审计明细、境内外约束（见 `docs/Q6-合规决策记录.md:16-26,30-39,63-72`，`:85-86` 明示该页不代表 Q6 已获批准）。百炼为**商业 API**，非 OSS，无许可证义务但受条款与数据合规约束。

## 6. 数据集 / 词表 / 样本

- 评测集 `server/tests/ai-eval/cases.jsonl` 共 **20 行**，每行 `labeled_by:"模板（待业务人员复核）"`、`labeled_at:"2026-10-15"` ⇒ **模板标注的工程种子集**，非临床金标；配套录制回放 `tests/ai-eval/recorded/_env.json`（`recorded_at 2026-10-15T16:27:35`、`departments ["内科"]`）+ 20 个 `case-*.json`。
- 标注口径："业务复核前只能证明没退化，不能证明临床正确"；仅内科有号 ⇒ `top1_eligible=0`；评测不进 final-verify（见 `docs/ai-eval/README.md:47-49,64-68,72-74`）。
- 危急征象词表 `RED_FLAG_TERMS` 为**自造示例级**（文件自述"这 20+ 条"，纯规则保险丝、排在模型之前），"不是临床完备集，要更全需临床输入"（见 `server/src/triage_redflag.cj:37-50,53-61,63`）。
- **无外部数据集、无真实个人数据**：样本为合成主诉，录制件只记科室名（全仓检索 0 命中外部数据集引用）。

## 7. 字体 / 图标 / 图片素材

- 全仓无 `.ttf/.otf/.woff/.woff2` ⇒ 使用系统字体；图标是**文本字形**（如 `Button('‹')`），无 `sys.symbol`/`SymbolGlyph`/`app.media` 引用（见 `common-core/src/main/ets/ui/CommonComponents.ets:47`、`ui/Theme.ets:89-90`）。
- 位图仅 `entry/src/main/resources/base/media/app_icon.png`（2777 B）与 `startIcon.png`（20093 B），形态与 DevEco 模板默认图标一致，**仓库内无来源/版权声明**。

## 8. 许可证结论表

| 组件 | 版本 | 用途 | 许可证 | 获取方式 |
| --- | --- | --- | --- | --- |
| 轻舟 QingZhou | v0.12.0+HEAD | 服务端 Web 框架 | **MIT** | 使用副本（源码快照） |
| MariaDB 驱动 | 2.0.2 | 数据库协议驱动 | **Apache-2.0** | 使用副本（静态编译） |
| Cangjie SDK / stdx | 1.2.0 / 1.1.3.1 | 编译器与标准库 | 华为 SDK 协议（仓库内无文本，需上游确认） | SDK 安装 + 随包分发运行时 DLL |
| OpenSSL | 3.5.7 | TLS / 加密 | 仓库内无文本，需上游确认（上游 3.x 为 Apache-2.0） | 系统 / Git for Windows 取 DLL |
| MariaDB Server | 11.4.13 | 数据库实例 | **GPLv2**（上游，仓库内无文本） | 便携版，不入库、不对外分发 |
| HarmonyOS 系统 Kit | SDK 内置 | 网络 / 存储 / UI / 日志 | 华为 SDK 协议 | 系统内置 |
| @ohos/hvigor-ohos-plugin | 随 DevEco | 构建插件 | 华为 SDK 协议 | DevEco 内置（构建期） |
| AGP / Kotlin / Gradle | 8.5.2 / 2.0.21 / 8.7 | 安卓构建链 | Apache-2.0 | 包管理器（构建期，不分发） |
| AndroidX / Compose | — | — | — | **未使用**（`android.useAndroidX=false`） |
| Vue / vue-router / Vite | ^3.4 / ^4.3 / ^5.0 | 上游演示件，**本项目未使用** | MIT | 使用副本（不参与构建） |
| 阿里云百炼（OpenAI 兼容） | qwen-plus / text-embedding-v3 | AI 分诊与向量 | 商业服务条款（非 OSS） | 外部 API 调用 |

**合规结论**：需注意的只有 **MariaDB Server 的 GPLv2**（当前仅自管实例、不分发，风险低；若对外分发便携包须随附 GPLv2 文本）。轻舟 MIT、MariaDB 驱动 Apache-2.0、安卓构建链 Apache-2.0 属宽松许可，义务仅为保留版权与许可声明，均已在仓内保留（`server/third_party/*/LICENSE`）。**最大缺口是 Cangjie 运行时与 OpenSSL 3 的 DLL 随部署包分发却无许可证文本**（见 §9.1）；自研代码在 34 个 `server/src/*.cj` 带 `SPDX-License-Identifier: MIT` 头，现已补**仓级 `LICENSE`（MIT，2026-10-17）**对齐。管理台与两端 UI 零第三方前端依赖，无 JS 许可传染问题。

## 9. 证据不足 / 需人工确认

1. **Cangjie 运行时 + OpenSSL 3 许可证文本缺失**（随部署包分发，仓内无副本）。
2. ~~**无根 `LICENSE`**~~ **已修（2026-10-17）**：新增仓库根 `LICENSE`（标准 MIT 文本，`Copyright (c) 2026 smart_hospital contributors`），与 34 个源文件的 SPDX 头一致。
3. **MariaDB 生产版本无口径**（`docs/DEV-DB.md` 只有开发/测试 11.4.13）。
4. **SDK 口径冲突**：`build-profile.json5:8` 的 `5.0.0(12)` vs `docs/FRONTEND-INTEGRATION.md:1775` 的 SDK 26.0.0/API 26。
5. **快照元数据过期**：qingzhou `cjpm.toml` 的 `0.1.0`/`cjc 1.0.5`、驱动 `readme.md` 徽章 `v1.0.0`。
6. **快照完整性未入构建**：`MANIFEST.sha256` 不校验；`admin-web/` Vue demo 是否该随快照保留需确认。
7. ~~**`docs/ADMIN-WEB.md:16` 措辞过期**~~ **已修（2026-10-17）**：改写为"`server/admin-web/` 内没有 `package.json`，也不参与 `build.ps1`；vendored 快照另有上游 Vue3 演示，与本管理台无关"。
8. **`app_icon.png` / `startIcon.png` 来源不明**（疑 DevEco 模板默认图标，无版权声明）。
9. **AI 出站合规未闭环**：无 DPA、无知情同意、无脱敏预处理、无出站审计明细（`docs/Q6-合规决策记录.md:63-72`）。
