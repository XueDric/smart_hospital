# 智慧医院智能导诊就诊系统

> 患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → 校验真实有号 → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。

---

## 当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 准备 | 读取文档 + 从 `cangjie_web` 搬运只读基线到 `baseline/` | ✅ 完成 |
| **P0** | **号源/挂号独立 MySQL 路径**：ADR + 服务端骨架 + 7 张表 + 原子扣减/幂等/退号 + 验收测试 **32/32**（`selftest` 29 项） | ✅ **完成**（含复查 rev.2 五项修复） |
| P1 | 挂号闭环：HTTP 路由 + 排班/挂号/取消接口 + 三端鉴权 + 并发压测 | ⏳ 下一步 |
| P2 | AI 分诊（加工具条目 + `verify_recommendation()` + 危急关键词兜底） | ⏳ |
| P3 | AI 能力中心（配置/Prompt/工具开关落 MySQL） | ⏳ |
| P4 | 预问诊 SSE + 电子病历 + 运营看板 | ⏳ |
| P5 | RAG 知识库 | ⏳ |

> P0 的完整说明（交付物 / 验收边界 / 本机环境 / 踩坑）见 **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)**。

---

## 目录结构

| 路径 | 是什么 | 能否改 |
| --- | --- | --- |
| [smart-hospital-project-brief.md](smart-hospital-project-brief.md) | **唯一上下文入口** —— 项目定位、已确认决策、可复用资产盘点、5 个硬骨头、里程碑、风险、待决问题 | ✏️ 本项目文档 |
| [docs/adr/](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) | **架构决策记录** —— ADR-0001 号源/挂号独立 MySQL 路径（P0 唯一架构级决策） | ✏️ 本项目文档 |
| [docs/P0-HANDOFF.md](docs/P0-HANDOFF.md) | P0 收尾说明：交付物、验收结果与边界、本机联调环境、P0 踩过的 12 个坑 | ✏️ 本项目文档 |
| [server/](server/README.md) | **智慧医院服务端**（仓颉 + 轻舟）：`src/` 5 个 `.cj` + 构建脚本 + README | ✏️ 本项目代码 |
| [baseline/](baseline/SNAPSHOT.md) | **只读参考基线** —— 复制自 `cangjie_web`，**352 文件 / 7.53 MB**，基线提交 `07a0922`（上传前已剔除机密材料，见其 §二·补） | 🚫 **只读，勿就地改** |
| [baseline/SNAPSHOT.md](baseline/SNAPSHOT.md) | 基线说明：来源/提交/排除清单/路径映射表/复用风险 | ✏️ 复制说明 |
| `entry/` | ⚠️ **目前尚不存在** —— 鸿蒙患者端将来落这里，取用 `baseline/entry/` 作模板 | — |

> 🔴 **关键约定**：`baseline/` 是素材库，**只读**。智慧医院的代码写在 `server/`、`entry/`，
> 需要哪块就从基线取模板**新写**，不要在基线里就地改 —— 基线保持可回查、可比对。

---

## 阅读顺序

1. **[smart-hospital-project-brief.md](smart-hospital-project-brief.md)** —— 整份读完即可接续，不需要回读原对话
   - ⚠️ §1 是**已决事项**，除非有新的外部约束，**不要重新讨论**
   - ⚠️ 标注「**推断**」的数字（尤其工期）都是**未实测的粗估**，落地前请自行验证
2. **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)** —— 当前进度在哪、怎么跑起来、环境是什么
3. **[docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)** —— 为什么号源/挂号要脱离内存 Store
4. [baseline/SNAPSHOT.md](baseline/SNAPSHOT.md) —— 基线里有什么、缺什么、链接怎么对上
5. [baseline/docs/qingzhou-api-fact-sheet.md](baseline/docs/qingzhou-api-fact-sheet.md) —— **轻舟 API 事实清单**（每条带 file:line，写接口前必读）
6. [baseline/docs/API-NOTES.md](baseline/docs/API-NOTES.md) —— 编译期 API 事实 + 45 条踩坑（**写仓颉前必读**）

---

## 基线快照包含什么

| 资产 | 落点 | 复用度 |
| --- | --- | --- |
| 轻舟框架 v0.12.0（SSE / 出站流式 / DB 抽象 / Trie 路由） | `baseline/server/third_party/qingzhou/` | ⭐⭐⭐⭐⭐ |
| **AI 编排**（工具白名单 / 三态降级 / 提议确认 / 风控） | `baseline/server/src/ai_*.cj` | ⭐⭐⭐⭐⭐ |
| 服务端源码 33 个 `.cj`（含 `mysql_store.cj` 1362 行量级） | `baseline/server/src/` | ⭐⭐⭐⭐⭐ |
| 7 套测试脚本（冒烟 440 / 契约 / 后台 / 运维 / AI 三件套） | `baseline/server/tests/` | ⭐⭐⭐⭐ |
| 鸿蒙 ArkTS 客户端（21 页面 + api/ + 7 状态仓 + Theme） | `baseline/entry/` | ⭐⭐⭐⭐ |
| Vue 3 管理端（源码 + 随仓库提交的 `dist`） | `baseline/server/admin-web/` | ⭐⭐⭐ |
| 29 份中文文档（六轮评审 / 容量基线 / 45 条踩坑） | `baseline/docs/` | ⭐⭐⭐⭐⭐ |

---

## 未决问题

见 [smart-hospital-project-brief.md §10](smart-hospital-project-brief.md)，共 6 条。

| # | 问题 | 状态 |
| --- | --- | --- |
| Q1 | fork 本仓库，还是新建空仓再选择性搬运？ | ✅ **已决**：新建工作区 + 选择性搬运 → 基线落在 `baseline/`，不带 `.git` 历史 |
| Q2 | 数据模型范围：先建哪几张表？ | ✅ **已决（P0）**：最小 7 张 —— `department` `doctor` `schedule`★ `appointment`★ `patient` `medical_record` `booking_idem`◆ |
| Q3 | 患者端页面范围：复用哪些既有页面？ | ⏳ 未决 |
| Q4 | 管理端是否复用 `baseline/server/admin-web`（Vue3）？ | ⏳ 未决 |
| Q5 | **单院区量级**：日门诊量？号源放出峰值并发？ | ⏳ 未决 —— **影响 P0 扣号路径是否要加重试/排队**（ADR-0001 §3 方案 C 的后手条件） |
| Q6 | AI 模型选型与合规 | ⏳ 未决 |
