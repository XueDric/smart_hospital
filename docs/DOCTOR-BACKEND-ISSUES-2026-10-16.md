# 医生端 → 后端：对接问题清单

日期：2026-10-16（UTC+8）。提交人：B 同学（医生端 + 管理端）。对象：后端。
代码基线：服务端 `365514366e6f6826ddfe7f1f62f81d1e6346431a`（`3655143`）；客户端为本工作区未提交改动。

本文只列出**我在实现医生端病历工作台（改进 2 剩余）与病历修订历史（改进 3 只读）时撞到的后端侧不一致**。医生端已按现有契约全部实现完毕，以下 4 条不需要等我，也不阻塞我。

**边界声明**：我**没有改任何服务端代码**，也不打算改。每条问题都附服务端源码位置，便于直接定位；改与不改、怎么改，由后端判断。契约措辞若需调整，`docs/FRONTEND-INTEGRATION.md` 的同一处我已在医生端那行做了标注，服务端小节留给后端改，避免两人同改一行。

**证据等级**：本文全部为**高置信源码路径 + 逻辑推演**，**未在真实数据库或设备上复现过**（问题 1 的并发路径是读代码推出的可达性论证，不是实测）。源码上成立不等于实测成立。

---

## 0. 结论

| # | 问题 | 严重度 | 需后端做什么 | 影响我的哪一步 |
|---|---|---|---|---|
| 1 | `EMR_CHANGED` 有第二条出口**完全不带** `error.fields`，违反你们自己钉住的 schema | ★★★ | 改代码（推荐）或改 schema | 冲突核对流程多一次全量往返 |
| 2 | 医生端**没有任何接口**给出患者姓名 | ★★★ | 先决策「刻意还是遗漏」，再定字段 | 队列页/病历页患者栏只能显示编号 |
| 3 | 既往病历列表的**排序键没进契约**，而它与 `LIMIT` 耦合、语义又与 `reopen` 冲突 | ★★ | 定排序键并写进契约 | 医生可能看不到「上次看的是什么」 |
| 4 | `error.fields` 值类型 schema 说 integer；`record_id` 的 `required` 与实现不一致 | ★ | 确认口径（类型保持 integer；`record_id` 二选一） | 客户端类型声明需收口 |

问题 1、3 是**契约与实现不一致**，建议优先；问题 2 需要先有产品/合规决策，不是纯技术问题。

---

## 1. ★★★ `EMR_CHANGED` 的第二条出口会**完全不带** `error.fields`，违反 schema

### 现象

乐观锁冲突返回 409 `EMR_CHANGED` 时，`error.fields` 有时**整个不存在** —— 而此时冲突是真实发生的。

### 证据

**(a) 契约明确要求 `fields` 必给。** `contract/schema/envelope-error-fields.schema.json:5-19` 声明
`error.required = ["code", "message", "fields"]`，且 `additionalProperties: false`；
`docs/FRONTEND-INTEGRATION.md:186-190` 写「它的形状由 `contract/schema/envelope-error-fields.schema.json` 钉住」。

**(b) 但实现有两条出口。** `server/src/http_p4.cj:320-331`：

```cangjie
if (out.currentUpdatedAt > 0) {
    let f = JsonObject()
    f.put("updated_at", JsonInt(out.currentUpdatedAt))
    f.put("updated_by", JsonInt(out.currentUpdatedBy))
    if (out.recordId > 0) {
        f.put("record_id", JsonInt(out.recordId))
    }
    throw apiErrorFields("EMR_CHANGED", "…（服务端当前版本见 fields）…", f)
}
throw apiErrorMsg("EMR_CHANGED", "…病历已被其他操作修改，请保留输入并重新读取后确认")
//   ↑ 这条一个字段都不带
```

**(c) 有一条可达路径**（`server/src/domain_emr.cj:941-950`）会置 `conflict = true` 却**从不设置 `currentUpdatedAt`**：

```cangjie
} catch (e: Exception) {
    // 同预约首次保存并发撞唯一键时明确冲突，不自动重放过时的预填内容。
    match (findByAppointment(appointmentId)) {
        case Some(latest) =>
            out.recordId = latest.id
            out.locked = latest.isLocked()
            out.conflict = !out.locked      // ← conflict = true，currentUpdatedAt 仍是 0
            return out
        case None => throw e
    }
}
```

`latest.updatedAt` / `latest.updatedBy` 就在这一层的手边，只是没有往下传，于是必然落到 (b) 的无 `fields` 出口。

### 可达性

**可达成**：同一次预约**首份病历并发建单**。

两个端同时保存一份**还不存在**的病历 → 双方都走 `!exists`（`domain_emr.cj:785-790`）→ 都执行 INSERT → 一方撞唯一键 → 落到上面这个 `catch`。
医生端在平板与电脑上同时开始写同一个新病人，就是这个场景。

### 连带矛盾：与文档承诺相反

`docs/FRONTEND-INTEGRATION.md:1422` 写「不带该字段 ⇒ 保持旧行为（**不校验**，用于兼容与首次保存）」，
`1423` 写「挂号单**还没有病历**时不校验（没有"当前版本"可比）」。

但按上面这条路径，一个**根本没带 `expected_updated_at`** 的请求也会收到 409 `EMR_CHANGED`。
即：**文档说首次保存不会冲突，实际会。**

### 顺带：`catch (e: Exception)` 过宽（健壮性）

`domain_emr.cj:941` 捕获的是**所有**异常。只要 INSERT 失败后能读到一条记录，任何失败（不只是唯一键冲突）都会被重写成「别人改了病历」+ 409。
若失败真因是长度/类型等错误，客户端会把它当冲突反复重试，且永远看不到真因。建议收窄到唯一键错误码。

### 客户端现状（我们不需要你们改代码也能活）

收到无 `fields` 的 409 后，我们会**再拉一次 `GET /doctor/visits/:id/record`**，从响应体的 `updated_at` 取基准（`feature-doctor/.../EmrEditPage.ets:449-478`）。
所以功能是通的，代价是**多一次全量病历往返**（正常路径下 `fields` 就够，不必再拉）。

### 期望后端（二选一，倾向前者）

- **(A) 推荐**：在 `domain_emr.cj:943-948` 的 `Some(latest)` 分支补两行
  `out.currentUpdatedAt = latest.updatedAt` / `out.currentUpdatedBy = latest.updatedBy`，
  让两条出口都能带 `fields`，与 schema 一致。首份并发的医生也能立刻拿到基准，省掉那次往返。
- **(B)** 若有意保留「有时不带」：把 schema 的 `fields` 改成可选，并在 §5.30.2 明确写出**什么条件下会缺**。
  同时请修 `1422`/`1423` 两句与首份并发行为不符的描述。

### 另有一条理论路径（判断不可达，仅作记录）

`domain_emr.cj:884-901`：UPDATE 影响 0 行（`n == 0`）后回读，若此时记录已被删（`None` 分支），
`conflict` 仍为 `true` 而 `currentUpdatedAt` 为 0 → 同样落到无 `fields` 出口。

我**在全仓没有找到删除病历的端点**，因此判断这条不可达，不必处理。
但若它当真可达，则「病历被删」回了 `EMR_CHANGED`（而不是 404 `EMR_NOT_FOUND`）会让医生去找一个不存在的新版本 —— 那时应换成 404。

---

## 2. ★★★ 医生端没有任何接口能给出「面前这位患者是谁」

### 现象

全仓检索 `patient_name` / `patientName`：**只出现在** `server/src/acceptance_p4.cj:428` 的**看板**禁用词表里。
**没有任何医生端端点下发患者姓名**，也没有任何请求/响应里存在患者姓名字段。

### 对比口径：医生姓名是给的，患者姓名不给

`doctor_name` 正常下发：

| 端点 | 依据 |
|---|---|
| `GET /api/v1/schedules` | §5.12，回 `department_name`/`doctor_name`/`doctor_title` |
| `GET /api/v1/doctors` | §5.21，回 `name`/`department_name`/`title` |
| `GET /api/v1/doctor/patients/:patientId/records` | §5.30.1 正文写「另加 `department_name`/`doctor_name` 等就诊上下文」 |

所以当前实际口径是「**同事的姓名随便给，患者的姓名一个不给**」。

### 影响

- 队列页只能显示「序号 3 · 患者 #101」（`feature-doctor/.../VisitQueuePage.ets:263`）。
- 病历页患者栏只能显示「患者 #101」（`feature-doctor/.../EmrEditPage.ets`，已留 `TODO`）。

§5.32 那一整套 `booked → arrived → waiting → visiting → done` 流程，存在意义就是「人在现场等叫号」；
但**叫号要喊的是名字**，医生拿着编号在真实诊室里没法核对身份。

**该缺口在 `docs/FRONTEND-INTEGRATION.md` §9 的 14 条缺口表里没有登记**（已逐条核对，无此条）。

### 期望后端

1. **先请明确：这是刻意（个保法 / 最小必要）还是遗漏？** 这一点决定了后面怎么写，我不能替你们判断。
2. 若**刻意**：请给出**允许下发的那一个最小标识**（例如手机号后 4 位、患者编号后 4 位、或姓名脱敏形式），
   否则叫号流程不可用 —— 现在医生除了一个数字没有任何可念出口的东西。
3. 若**遗漏**：请在 `GET /doctor/visits`、`GET /doctor/visits/:id/record`、
   `GET /doctor/patients/:patientId/records` 三处补 `patient_name`（需要的话再加性别）。
4. ⚠ `acceptance_p4.cj:428` 那张禁用词表**只针对看板**，改医生端端点不会碰到它。
   但如果你们的门禁是**全局 grep**，需要同步调整 —— 这一条请你们判断，我不动。

### 前端现状

患者栏已占位显示「患者 #patientId」并留 `TODO`。**后端一补字段，我们立刻接**，无需改其他逻辑。

---

## 3. ★★ 既往病历列表：排序键没进契约，而它与 `LIMIT` 耦合、语义又与 `reopen` 冲突

### 现象

`docs/FRONTEND-INTEGRATION.md` §5.30.1（既往已定稿病历）**完全没提排序**。
对照 §5.31.2 明确写了 `order: "id_desc"` —— 本仓的习惯是显式声明顺序，因此 §5.30.1 的沉默更像漏写而非有意。

### 服务端实际（`server/src/domain_emr.cj:738`）

```cangjie
sql = sql + " ORDER BY updated_at DESC, id DESC LIMIT ?"
```

### 问题 (a)：`LIMIT` 跟着排序走，客户端修不了

服务端**先排序、再取 5 条**，所以「**哪 5 条**」由排序键决定。
即使客户端改成按 `visit_date` 排，也只是把服务端已经挑好的那 5 条重排一遍 —— 挑错了就是真的缺，客户端无从补救。

⇒ 排序键实际上是**契约的一部分**，不是展示层的选择。

### 问题 (b)：`updated_at DESC` 的语义与「既往就诊」不符，且会被 `reopen` 破坏

`updated_at` 是「最后**被编辑**」的时间，不是「最后**就诊**」的时间。而 `reopen`（管理员解锁重写）**会改 `updated_at`**。

于是：管理员解锁重写一份**三年前**的老病历后，它会跳到既往列表**第一位**，把最近一次就诊挤出前 5 条之外。
医生打开工作台，反而看不到上次看的是什么 —— 与「同屏看本次 + 既往」的初衷相反。

### 期望后端

1. 请把排序键写进 §5.30.1。倾向于按**就诊时间**（`visit_date DESC`，必要时补 `period`）或 `created_at DESC`，
   而不是 `updated_at`。改成按就诊时间后，`LIMIT` 的选取也随之变正确 —— 这才是想要的效果。
2. 无论最终选哪个，请明确二选一的性质：
   - 「**顺序是契约的一部分**，客户端不得重排」；或
   - 「**顺序不保证**，客户端自行排序，但服务端保证按 **X** 取前 N 条」。
   目前两种都不是，客户端只能靠读 SQL 猜。

### 前端现状

我们目前按 `updatedAt` 倒序排（与服务端一致），代码里注明「契约未规定顺序，不得依赖」。
后端一改排序键，我们跟着调整展示即可。

---

## 4. ★ `error.fields` 的值类型与 `record_id` 的 `required`

### (a) 值类型：schema 说 integer

`contract/schema/envelope-error-fields.schema.json:18-24` 把 `updated_at` / `updated_by` / `record_id` 全声明为 `"type": "integer"`。

我方 `common-core/src/main/ets/network/ApiError.ets:30` 声明的 `fields` 是 `Record<string, string>` ——
**这是我这边的类型松，不是你们的 bug**（`HttpClient` 里是不检查的强转，数字能活到运行时，我再用 `fieldsNumber()` 按数字读）。

两点对齐：

- 请**保持 integer**，不要为了迁就客户端改成字符串，也不要出现「有时数字有时字符串」。
- 我会把客户端类型收口成「值可能是数字或字符串，一律按数字读」。

### (b) `record_id`：`required` 与实现不一致

`server/src/http_p4.cj:324` 是 `if (out.recordId > 0)` 才写入 `record_id`，而 schema 把它列为 **required**。

我没能构造出「`fields` 存在但 `record_id` 缺失」的可达路径
（`currentUpdatedAt > 0` ⇒ 记录必然存在 ⇒ id 必然 > 0），所以这更像**防御性代码与 schema 的口径不一致**，而非实际缺失。

请二选一，只要 schema 与实现对得上：

- 去掉那个 `if`（schema 说了必给）；或
- 把 `record_id` 从 schema 的 `required` 移出。

---

## 5. 已核对、按契约实现、**无异议也不用回复**的契约点

列出这些是为了表明我逐条读过契约，不是遗漏：

| 契约点 | 我的处理 |
|---|---|
| `limit` 非法 / 超 20 **静默回落 5**（与患者侧同脾气） | 按此实现，不做本地校验 |
| `GET /doctor/patients/:patientId/records` 对「不是我的患者」回 **404 而非 403**（防枚举） | 按**正常态静默处理**，不弹错（`DoctorRepository.ets` 注释已记） |
| 该端点只返回 `status='locked'` 的病历 | 已知悉，界面文案按「既往已定稿」措辞 |
| `EMR_LOCKED` **优先于** `EMR_CHANGED`（即使 `expected_updated_at` 也过期） | 两个 409 **分开处理**，不合并；先判 `EMR_LOCKED` |
| `reopen` 是 `Action.ManageRecordRevision`（**仅管理员**），医生调一律 403 | 医生端**完全不调该端点**，版本历史做成**只读** |
| `lock` 响应 `revision_version = 0` = 审计行未写上、但病历动作已成功 | 按「版本号未知」显示，**不当失败重试** |
| 修订版本是**稀疏**的（只有 `lock`/`reopen` 落版本，草稿 PUT 不落） | 界面文案不暗示「一版 = 一次保存」 |
| `version=1` 不给 `against` ⇒ **400**（不退化成 v1 跟自己比） | 在 v1 上不给「对比」入口 |
| `diff` 的 `changed` / `changed_count` **由服务端判定** | 客户端**不重算**，直接读 `changed_count` |
| `REVISION_NOT_FOUND` 是 **404 而非空对象** | 按此渲染，绝不显示成「七段全空的版本」 |
| `status_label` 由服务端下发，客户端不抄中文表 | 优先用 `status_label`，本地映射仅作兜底 |
| 队列顺序由服务端给（待处理优先），客户端不重排 | 不按 `seq_no` 重排 |

---

## 附：证据索引

| 位置 | 内容 |
|---|---|
| `contract/schema/envelope-error-fields.schema.json:5-24` | `EMR_CHANGED` 错误信封：`error` 要求 `fields` 必给；三个值声明为 `integer` |
| `server/src/http_p4.cj:320-331` | 两条出口：`currentUpdatedAt > 0` 带 `fields`，否则**不带** |
| `server/src/http_p4.cj:324` | `record_id` 的 `if (out.recordId > 0)` 条件写入 |
| `server/src/domain_emr.cj:805-811` | 乐观锁冲突判定（`exists && expectedUpdatedAt > 0 && updatedAt != expected`） |
| `server/src/domain_emr.cj:884-901` | UPDATE 影响 0 行后回读；`None` 分支留 `conflict=true` 且无 `currentUpdatedAt` |
| `server/src/domain_emr.cj:930-951` | INSERT 唯一键冲突被重写成冲突；**未设置 `currentUpdatedAt`** |
| `server/src/domain_emr.cj:738` | `ORDER BY updated_at DESC, id DESC LIMIT ?` |
| `server/src/acceptance_p4.cj:428-437` | **看板**禁用词表（含 `patient_name`）—— 仅看板，勿扩大到医生端 |
| `docs/FRONTEND-INTEGRATION.md:186-190` | 「`fields` 形状由该 schema 钉住」 |
| `docs/FRONTEND-INTEGRATION.md:1409-1427` | §5.30.2 乐观锁契约（`1422`/`1423` 与首份并发行为不符） |
| `docs/FRONTEND-INTEGRATION.md:1377-1407` | §5.30.1 既往病历（**未提排序**） |
| `docs/FRONTEND-INTEGRATION.md:1916-1938` | §9 缺口表（**无「医生端看不到患者姓名」一条**） |

## 附：待办（后端勾）

- [ ] **1**(A) 两条出口都带 `fields`：`domain_emr.cj:943-948` 补 `currentUpdatedAt` / `currentUpdatedBy`
- [ ] **1** 收窄 `domain_emr.cj:941` 的 `catch (e: Exception)` 到唯一键错误
- [ ] **1** 修正 §5.30.2（`1422`/`1423`）与首份并发行为不符的描述；或改 schema 声明 `fields` 可选
- [ ] **2** 决策：患者姓名是刻意不给还是遗漏；给出允许下发的最小标识
- [ ] **2** 若补字段：`GET /doctor/visits`、`…/record`、`…/patients/:patientId/records` 三处
- [ ] **3** 定既往病历列表的排序键并写进 §5.30.1；声明「顺序是否为契约」
- [ ] **4** 确认 `fields` 值保持 integer；`record_id` 的 `required` 二选一
