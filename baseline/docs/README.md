# 文档目录（中文导航）

> 文件名保持英文不变（全仓有 488 处引用，改名会断链）；**这一页就是用来找文件的**。
>
> 每一行右边都写了**实际文件名**，方便你在编辑器里直接定位。

---

## 一、按「我要做什么」找

| 我要… | 看这份 | 文件名 |
|---|---|---|
| **刚接手项目，先搞清楚现状** | 交接说明：项目现状、已冻结设计、验证过的事实、未决事项 | `HANDOFF.md` |
| **把服务端跑起来** | 服务端指南 —— 构建 / 运行 / 测试；**含「带 AI 能力启动」** | `server-guide.md` |
| **在本机部署 + 联调** | 本机部署一页上手（§0.5 是联调速查：三条命令） | `local-deploy.md` |
| **正式部署到 Windows 并验证** | 部署与验证步骤、目标配置基线 | `deploy-windows-verify.md` |
| **写服务端接口** | **接口设计的唯一权威**（40 个接口逐条定义） | `api-design.md` |
| **判断某个功能要不要做** | 范围基准：11 页面、6 张表、19 条业务规则、权限矩阵 | `v1-scope.md` |
| **编译报奇怪的错 / 撞上已知坑** | **编译期 API 事实清单 + 45 条踩坑记录** | `API-NOTES.md` |
| **接 AI 能力（服务端）** | 服务端接入 AI 的落地指南：配置项、接口语义、验收判据 | `llm-backend-guide.md` |
| **接 AI 能力（客户端）** | 客户端接入指南：`source` 呈现规则、界面契约 | `llm-frontend-guide.md` |
| **搞懂 AI 出站调用的设计口径** | 服务端大模型出站调用规范（配置项 / 重试 / 预算 / 并发闸门） | `llm-client-spec.md` |
| **AI 出问题了 / 值班排障** | **AI 运维与排障**：三十秒判断状态 · fallback 排查 · 429 · 审计 · 检查清单 · **§7.1 单实例假设与已知边界** | `llm-ops-guide.md` |
| **看 AI 模块审到什么程度** | AI 模块审查报告（三轮 · 46 条 · 时点记录） | `ai-module-review.md` |
| **看服务端代码评审结论** | 代码评审报告（六轮） | `code-review.md` |
| **跑客户端 / 打包客户端** | 客户端构建与现状（含 JBR / SDK 两个环境坑） | `client-build.md` |
| **给前端提 bug / 交接前端** | 客户端 bug 交接单；前端对接精简版 | `client-bug-handover.md` · `frontend-brief.md` |
| **客户端的成员模块（P06/P07）** | D 模块交付说明 | `d-member-module.md` |
| **对齐 UI 设计规格** | UI 设计规格 ↔ 服务端一致性审计（13 页逐条） | `ui-spec-conformance-review.md` |
| **看性能/容量数据** | 容量基准与四项性能改造（改造前后矩阵） | `capacity-baseline.md` |
| **搞数据库 / 持久化** | 轻舟数据库抽象层与 MySQL 接入；迁移评估 | `mysql-backend.md` · `club-server-mysql-assessment.md` |
| **查竞赛要求** | 仓颉杯 2026 竞赛要求 | `cangjie-cup-2026-requirements.md` |
| **角色配色** | 角色配色方案 | `role-color-scheme.md` |
| **前端分工** | 前端工作总结 / 分工 / 新增任务分工 | `前端工作总结.md` · `FRONTEND_DIVISION(1).md` · `前端新增任务分工.md` |

---

## 二、按主题分组

### 🔧 上手与部署
| 文档 | 文件名 |
|---|---|
| 交接说明（**接手先看**） | `HANDOFF.md` |
| 服务端指南（构建/运行/测试/**带 AI 启动**） | `server-guide.md` |
| 本机部署一页上手 | `local-deploy.md` |
| Windows 部署与验证 | `deploy-windows-verify.md` |

### 📐 规范与契约（改代码前必读）
| 文档 | 文件名 |
|---|---|
| **接口设计唯一权威** | `api-design.md` |
| 范围基准（11 页面 / 6 表 / 19 规则 / 权限矩阵） | `v1-scope.md` |
| 编译期 API 事实 + 踩坑记录 | `API-NOTES.md` |
| UI 设计规格一致性审计 | `ui-spec-conformance-review.md` |

### 🤖 AI 能力（Part 7）
| 文档 | 文件名 |
|---|---|
| **运维与排障**（值班先看） | `llm-ops-guide.md` |
| 服务端接入落地 | `llm-backend-guide.md` |
| 客户端接入落地 | `llm-frontend-guide.md` |
| 出站调用规范（设计权威） | `llm-client-spec.md` |
| AI 模块审查报告（三轮 46 条） | `ai-module-review.md` |

### 📱 客户端
| 文档 | 文件名 |
|---|---|
| 构建与现状 | `client-build.md` |
| bug 交接单 | `client-bug-handover.md` |
| 对接精简版 | `frontend-brief.md` |
| D 模块（成员名录/详情）交付说明 | `d-member-module.md` |
| 角色配色方案 | `role-color-scheme.md` |
| 前端工作总结 / 分工 | `前端工作总结.md` · `FRONTEND_DIVISION(1).md` · `前端新增任务分工.md` |

### 🗄 数据与性能
| 文档 | 文件名 |
|---|---|
| 轻舟 DB 抽象层与 MySQL 接入 | `mysql-backend.md` |
| 迁 MySQL 评估 | `club-server-mysql-assessment.md` |
| 容量基准与性能改造 | `capacity-baseline.md` |

### ✅ 评审记录（时点快照，**不要改写**）
| 文档 | 文件名 |
|---|---|
| 服务端代码评审（六轮） | `code-review.md` |
| AI 模块审查（三轮） | `ai-module-review.md` |

### 🏆 竞赛
| 文档 | 文件名 |
|---|---|
| 仓颉杯 2026 要求 | `cangjie-cup-2026-requirements.md` |

---

## 三、三套 AI 测试脚本（在 `server/tests/`，不在 docs 里）

| 脚本 | 验什么 | 要数据库吗 |
|---|---|---|
| `ai-check.ps1` | 参数与配置解析（**不需要库**） | ❌ |
| `ai-e2e.ps1` | 协议与降级路径（本地桩，可重复、不花钱） | ✅ |
| `ai-real.ps1` | **真实模型联调**（会花钱） | ✅ |

启动参数见 `server-guide.md`「带 AI 能力启动」；排障见 `llm-ops-guide.md`。

---

## 为什么文件名不改成中文

全仓有 **488 处**引用这些文件名（代码注释 44 · 文档间 361 · README 63 · 脚本 20）。
改名要同步改写全部引用并逐项核验，漏一处就是死链；而且这些引用大量出现在
**队友正在改的文件**里，重命名几乎必然冲突。

**用这一页导航比改文件名更直接** —— 你不用猜某个文件叫什么，按"我要做什么"查即可。

---

## 附：编码约定（回应评审 P3-6）

评审提过「`docs/README.md` 无 BOM，PowerShell 5.1 下中文显示乱码」。**核实结论：**

- **全仓 26 份 `docs/*.md` 以及根 `README.md` 都无 BOM** —— 这不是本文件独有的问题
- 本仓的 BOM 约定**只针对 `server/**/*.ps1`**（含中文的 PowerShell 脚本必须
  UTF-8 with BOM，否则 PS 5.1 按 ANSI 解析会让脚本**语法报错**）。`.md` 一直是无 BOM 的
- 所以**没有给这一个文件单独加 BOM** —— 那会让它与其他 25 份不一致，
  且 BOM 在部分 Markdown 工具里会显示成多余字符

**在 PS 5.1 里读中文文档**请用 `Get-Content <文件> -Encoding UTF8`，不要依赖 BOM。
若确实想改成「全部 `.md` 都加 BOM」，那是一次仓库级约定变更，欢迎提出来一起定。
