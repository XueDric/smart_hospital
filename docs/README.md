# 文档导航

> 这份目录按**大赛要求的 6 项提交材料**组织。留在这里的是提交与评审要直接读的；
> 过程记录（阶段交接、联调写实、接口手册、UI 规范等）在 [`archive/`](archive/)，需要时再翻 —— 它们是"当时确实这么干过"的痕迹，不是答辩主线。

## 一、6 项提交材料 → 看哪份

| 赛制要求 | 对应文档 |
| --- | --- |
| ① 项目说明（背景 / 需求分析 / 功能模块 / 创新点 / 应用价值） | [PROJECT-OVERVIEW.md](PROJECT-OVERVIEW.md) |
| ② 系统设计（总体架构 / 模块划分 / 接口设计 / 数据流转 / 关键技术） | [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md)、[adr/](adr/)（号源与挂号的独立 MySQL 路径，含 rev.2–rev.7 修订史） |
| ③ 源代码仓库与版本历史 | 本仓库；提交主题与阶段在 [../CHANGELOG.md](../CHANGELOG.md) |
| ④ 可运行程序包 / 部署文档 / 环境配置 | [../release/](../release/)（分发包 + HAP + APK + 构建日志 + 实跑截图）、[DEPLOYMENT.md](DEPLOYMENT.md)、[DEV-DB.md](DEV-DB.md) |
| ⑤ 演示视频（主要业务流程 + 核心智能功能） | [../video/](../video/)（成片 + 生产链路与已知边界）、[答辩材料-2026-10-17.md](答辩材料-2026-10-17.md)（5 分钟陈述稿 + 9 步演示脚本）、[答辩演示-2026-10-21.pptx](答辩演示-2026-10-21.pptx)（10 页，备注页即讲稿） |
| ⑥ 开源组件 / 第三方模型 / 外部 API / 数据集使用说明 | [THIRD-PARTY.md](THIRD-PARTY.md)、[轻舟共建说明.md](轻舟共建说明.md)（框架层做了什么、没做什么）、[向量检索说明.md](向量检索说明.md)（RAG 走的是关键词路，向量路未接） |

## 二、评审关心的另外三份

| 文档 | 回答什么 |
| --- | --- |
| [项目真实性与分工说明.md](项目真实性与分工说明.md) | 谁写了哪块、起点在哪、是不是 fork、既有成果与本次新增的边界 |
| [AI-工具使用声明.md](AI-工具使用声明.md) | 产品内的 AI 与开发期用的 AI 分别是什么、各自影响了哪些文件、怎么核验 |
| [验收实跑-2026-10-21.md](验收实跑-2026-10-21.md) | 全部数字的现场复现记录（含原文输出、四步复现、我们踩过的坑） |

## 三、数字的唯一来源

[交付快照.md](交付快照.md) 是版本、体积、哈希的唯一锚点，由 `tools/check-snapshot.ps1` **机器校验**；
断言数由 `server/tests/doc-counts.ps1` 对账。任何一处数字变动，先跑这两个脚本再加提交。

> ⚠ 这两个脚本硬编码了若干路径（`README.md`、`docs/PROJECT-OVERVIEW.md`、`docs/SYSTEM-DESIGN.md`、`docs/DEPLOYMENT.md`、`docs/adr/ADR-0001-号源与挂号独立MySQL路径.md`、`docs/交付快照.md`）—— **这几份不能挪位置**，挪了门禁会红。

## 四、`archive/` 里有什么

| 文件 | 性质 |
| --- | --- |
| [PHASE-HANDOFFS.md](archive/PHASE-HANDOFFS.md) | P0–P5 六阶段的交接记录（当时的验收数与已知边界） |
| [联调记录-2026-10-18.md](archive/联调记录-2026-10-18.md) | 三端 + 安卓实机走查记的 10 条 BUG 与处置 |
| [录屏脚本-2026-10-21.md](archive/录屏脚本-2026-10-21.md) | 成片的分镜脚本与录制/剪辑链路 |
| [FRONTEND-INTEGRATION.md](archive/FRONTEND-INTEGRATION.md) | 客户端与服务端的联调手册（体量最大的一份） |
| [HARMONY-INTERFACE-GUIDE.md](archive/HARMONY-INTERFACE-GUIDE.md) | 鸿蒙端接口对接说明 |
| [ADMIN-WEB.md](archive/ADMIN-WEB.md) | 管理台（零框架单页）的页面与接口对照 |
| [UI-DESIGN.md](archive/UI-DESIGN.md) | 视觉规范：色板、字阶、间距、热区 |
| [Q6-合规决策记录.md](archive/Q6-合规决策记录.md) | 医疗合规相关决策的留痕 |
