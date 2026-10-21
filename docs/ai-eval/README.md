# AI 分诊评测（改进 7）

> 本目录是**质量**证据的归档地：报告 `docs/ai-eval/<date>.md` + 机器可读指标 `docs/ai-eval/<date>.metrics.json`。
> 工程正确性（降级 / 超时 / 解析失败 / 安全过滤）由进程内用例 `server/src/acceptance_ai_call.cj` 覆盖，
> 两者互补，**不要合并**（前者问"结论准不准"，后者问"代码按不按规矩走"）。

## 1. 文件分工

| 文件 | 作用 |
| --- | --- |
| `server/tests/ai-eval/cases.jsonl` | 标注集：一行一个 JSON 用例（见 §3） |
| `server/tests/ai-eval/run-ai-eval.ps1` | 跑评测并写报告（两种模式，见 §2） |
| `server/tests/ai-eval/recorded/case-*.json` | **录制样本**：实时模式把每条响应与当时的判定落盘，回放模式只读它 |
| `server/tests/ai-eval/recorded/_env.json` | 录制当时的环境快照（"有号科室"清单） |
| `docs/ai-eval/<date>.md` | 给人看的报告（自动生成，**不要手工改**） |
| `docs/ai-eval/<date>.metrics.json` | 同一批数字的机器可读版本（给看板/趋势用） |

## 2. 两种模式

```powershell
# 回放（默认）：离线、可重复、不烧钱；只读 recorded/，不连服务端
& .\tests\ai-eval\run-ai-eval.ps1 -Mode replay

# 实时：打真实服务端（要 -Base 与管理员口令；本机没有 AI key 时 source 会是 rules）
& .\tests\ai-eval\run-ai-eval.ps1 -Mode live -Base http://127.0.0.1:18092 -AdminPw <口令>
# 实时 + 重录样本（会覆盖 recorded/，请连报告一起提交）
& .\tests\ai-eval\run-ai-eval.ps1 -Mode live -Base ... -AdminPw ... -Record
```

常用参数：`-Cases <path>`（默认 `cases.jsonl`）、`-Limit N`（只跑前 N 条，冒烟用）、`-OutDir <dir>`。
退出码：`0` 成功；`2` 回放时有用例**没有录制样本**；`3` 用例集为空。

**回放可重复性自检**：回放模式连跑两次，两次打印的 `★ 指标指纹` 必须相同（实测
`41dc644dcb0034d0`）。指纹覆盖**模式 + 指标 + 用例 id 集合**，不含墙上时间——所以
它能在"换了模板 revision 或改了标注"时变红，而不会因为"今天几号"变红。

## 3. 用例格式（一行一个 JSON，UTF-8 无 BOM）

```json
{"id":"case-0001","chief_complaint":"咳嗽三天，有黄痰，晚上躺下更厉害，没有发烧",
 "expected_departments":["呼吸内科"],"expected_red_flag":false,
 "note":"典型急性支气管炎，非急症","labeled_by":"模板（待业务人员复核）","labeled_at":"2026-10-15"}
```

- `expected_departments`：**按优先级排序**（第 1 个是 Top1 的期望）；写科室**名称**（与 `departments.name` 同口径）。
- `expected_red_flag`：是否应当转急诊/红标。
- `labeled_by` / `labeled_at`：**必填且要诚实**。当前 20 条是工程侧按规则引擎现状标注的**种子**，
  标的是"规则引擎在无 AI 时应给出的科室"，`labeled_by` 写的是"模板（待业务人员复核）"——
  业务人员复核前，这份基准只能证明"没退化"，不能证明"临床正确"。

## 4. 指标口径（都在 `metrics.json` 里）

| 指标 | 算法 |
| --- | --- |
| 科室 Top1 | 命中数 / **可判定用例数**（见下） |
| 科室 Top3 | 期望科室出现在前 3 个候选里的比例 |
| 红标召回 | `expected_red_flag = true` 且真的红标的比例 |
| 红标误报 | `expected_red_flag = false` 却被判红标的条数 |
| 降级率 | **模型侧失败**：`degrade_reason` 非空**且不是** `RED_FLAG` 的比例 + 各 `degrade_reason` 计数（与 `/admin/ai/triage-stats` 同一判据；2026-10-16 复核改正，此前是 `source != "model"` —— 那个口径把"规则直接判红标"算成了 AI 失败） |
| 红标旁路 | `degrade_reason = "RED_FLAG"` 的条数（规则判红标、没调模型，属**良性**旁路，**不计入降级率**） |
| 耗时 p50/p95 | **最近秩法**（`rank = (p*n + 99) / 100`，夹到 1..n），整数毫秒**不插值** |
| 模型/模板 | 本次响应里出现的 `model_id` / `model_name` / `prompt_revision` 集合 |

**"可判定用例数"为什么可能小于总数**：科室命中只有在**这台环境真的有号**时才有意义——
分诊给一个"本院没排班"的科室不算错。评测会先扫一遍"当前有可挂号源的科室"，只对
期望科室落在其中的用例计 Top1/Top3，并把其余用例在报告里列成"本环境不可判定"。
> 本机现状：只有 `内科` 有号 ⇒ `top1_eligible = 0`，报告里如实写"本环境可判定 = 0"。
> 接上真实排班数据后重跑即可得到真实命中率。

## 5. 与门禁的关系

**评测不进 `final-verify.ps1`**：它依赖真实模型与 key、耗时以分钟计、且结果随环境变化，
放进发布门禁会让"门禁红"与"模型质量差"混成一件事。发布前**手动**跑一次并归档报告即可。
（排障端点与遥测贯通本身**在**门禁里：`server/tests/ai-telemetry-check.ps1`，53 条 live 断言。）

## 6. 接上真实模型后怎么用

1. 先在管理台配好 AI（`ai.key_ref` / 默认对话模型），确认 `/api/v1/triage` 的 `source` 变成 `model`；
2. `-Mode live -Record` 重录样本 ⇒ 覆盖 `recorded/`，报告与指标一并提交；
3. 与上一版报告比 Top1/Top3、红标召回、降级率、p50/p95；改 `prompt_revision` 前后的对比就是"这版模板有没有变好"的证据；
4. 把 `docs/ai-eval/<date>.md` 摘要贴进发布说明（管理台的评测报告页后续直接读这个目录）。
