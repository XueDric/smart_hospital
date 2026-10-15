/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== schema.cj —— 最小表集 DDL（P0）=====================================
 *
 * 归属：**号源 / 挂号域**（P0 的唯一新域）。
 *
 * ⚠ 架构决策见 docs/adr/ADR-0001-号源与挂号独立MySQL路径.md
 *   - `schedule`（排班/号源）与 `appointment`（挂号单）走**直接 SQL**，
 *     **不进内存 Store**，由 MySQL 权威；扣减与归还都用**一次成功的原子自减/自增**
 *     （`remain_num > 0` / `remain_num < total_num` 在同一条 UPDATE 内原子求值）。
 *     ⚠ 2026-10-07 rev.3 起**不再用 version 乐观锁**：实测它在最穷工况下
 *     少卖 15%~50%，且并发退号会永久丢号源（同一根因）。见 ADR rev.3/rev.4；
 *   - 其余表（department / doctor / patient / medical_record）为配套最小集，
 *     本阶段只建表，业务路径在 P1+ 落地。
 *
 * 口径依据（搬迁前的服务端，只读参考）：
 *   - SCHEMA_DDL 写法照搬迁前的 mysql_store.cj:313
 *   - 参数化 exec(sql, Array<DbValue>) 见 轻舟 db.cj:128
 *   - bindSql 会把 ? 按序替换为类型感知安全字面量（db.cj:113-131），
 *     所以 DDL 走无参 exec，数据操作走带 ? 的 exec
 *
 * ⚠ 字符集：全表 utf8mb4。搬迁前踩过"驱动握手写死 utf8mb3 → 一个 emoji 让之后
 *   所有写入持续 500"的坑（搬迁前的 mysql 接入文档 §12.10），
 *   建连后必须 SET NAMES utf8mb4（见 db_bootstrap.cj）。
 */

package qingzhou

/* ⚠ P5 起需要 ArrayList：仓颉的 Array 不支持 `+`，合并 DDL 两个数组只能靠它。 */
import std.collection.*

/* ===================== 表名常量 ===================== */

/*
 * 表名集中在此，避免各处字符串拼写漂移。
 *
 * ★ 域划分（ADR-0001 §4.2/§4.3）：
 *   `BOOKING_DOMAIN_TABLES` = 号源/挂号**业务状态**表，走直接 SQL（**仅此两张**）。
 *
 * ⚠ **表名必须避开搬迁前的内存 Store 表名**（P1 口径隐患；这条纪律**长期有效**）：
 *   搬迁前的内存 Store 占用了一批表名（`idem`、`tokens` 等，见
 *   `搬迁前 mysql_store.cj:891-892` 的 `PersistedState`，DDL 同名）。
 *   P1 引入内存 Store 后，整库刷盘会 `replaceBatched(<表名>, …)` ——
 *   本侧若用了同名表，就会与搬迁前**争同一张表**。
 *   所以本侧一律另起名字：`auth_token`（不是 `tokens`）。
 *
 *   📌 历史上本侧曾有一张 `booking_idem`（挂号幂等登记表）。它在 2026-10-07
 *   **连同实现一起删除**：幂等已由「`(patient_id, client_token)` 唯一索引」完整保证，
 *   那张表在生产路径上从未被调用（属死代码）。详细取舍见 ADR-0001 §7 第 7 条。
 *   → 因此现在**没有任何**以 `idem` 命名的表，但上面的命名纪律仍然适用。
 */
public let TABLE_DEPARTMENT: String = "department"
public let TABLE_DOCTOR: String = "doctor"
public let TABLE_SCHEDULE: String = "schedule"
public let TABLE_APPOINTMENT: String = "appointment"
public let TABLE_PATIENT: String = "patient"
public let TABLE_MEDICAL_RECORD: String = "medical_record"

/*
 * 鉴权表（P1 令牌体系）。
 *
 * ⚠ 命名同样避开搬迁前：搬迁前的内存 Store 占用了 `tokens`（`mysql_store.cj:891`）。
 *   所以本侧叫 **`auth_token`**；账号表叫 `auth_user`（搬迁前没有同名表，
 *   但加 auth_ 前缀是为了让"这是鉴权域"一眼可辨）。
 */
public let TABLE_AUTH_USER: String = "auth_user"
public let TABLE_AUTH_TOKEN: String = "auth_token"
/*
 * ★ 登录失败计数 / 锁定（2026-10-07 增，P1 安全加固）。
 *
 * ── 为什么**单独一张表**，而不是在 auth_user 上加两列 ─────────────────────
 * 关键在于：**账号不存在时也必须计入限流**。
 *   若把计数放在 `auth_user` 行上，那么"对不存在的登录名狂试"就**完全不受限** ——
 *   而这恰好是攻击者试用户名的手法（也能把 PBKDF2 当 CPU 放大器打）。
 *   单独建表后，任何登录名（存在与否）都能有一行计数。
 *
 * ── 为什么键是**哈希**而不是登录名原文 ───────────────────────────────────
 *   ① 防的是"库被读走后拿到一份'谁被撞过库'的名单"；
 *   ② 让"不存在的登录名"与"存在的登录名"在**存储层**也无法区分（口径统一）。
 *
 * ⚠ 表名同样避开搬迁前的内存 Store 的表名（见文件头纪律）—— 搬迁前没有这张表。
 */
public let TABLE_AUTH_ATTEMPT: String = "auth_login_attempt"

/* 号源/挂号**业务状态**表 —— 唯二走直接 SQL 的业务表（ADR-0001 §4.3）。 */
public let BOOKING_DOMAIN_TABLES: Array<String> = [TABLE_SCHEDULE, TABLE_APPOINTMENT]

/*
 * ★ 预问诊会话表（P2）。
 *
 * ── 为什么单独一张表、且**不**属于上面任何一类 ────────────────────────────
 *   · 不属 `BOOKING_DOMAIN_TABLES`：它不参与号源扣减，没有并发争抢语义；
 *   · 不属内存 Store 负责的配套域：它是**医疗数据**，必须立刻持久化
 *     （内存 Store 是"整表替换"范式，会话数据进去会被别的写入牵连）。
 *   ⇒ 它走**直接 SQL**，但**不是**"号源域"—— ADR-0001 §4.3 的范围锁死锁的是
 *     "`schedule`/`appointment` 只准 `BookingRepo` 写"，本表由 `PrevisitRepo` 独占。
 *     两者互不越界，所以锁死关系没有被破坏。
 *
 * ── 为什么要落库而不是放内存（P2 的具体理由）────────────────────────────
 *   ① 多轮对话跨请求：轻舟的 handler 是**同步**的，会话状态必须在请求之间存活。
 *      放进程内存 ⇒ 重启即丢；本项目已定"不做 Redis"的路线（brief §5.1）。
 *   ② 问诊单本身就是要长期保留的**患者档案素材**，迟早落库 —— 现在落，将来不必迁。
 *
 * ⚠ `form_json` 存序列化后的问诊单：六个槽位是**稳定的最小集**，
 *   为它建六列会让"加一个问诊项"变成一次 DDL 变更。
 *   JSON 列让加项只是改 `intakeSlots()` 一处 —— 与"口径只留一处"同一条纪律。
 *   （对照：参考系统也用 MySQL JSON 存 `kb_chunk.embedding`，同一思路。）
 */
public let TABLE_PREVISIT: String = "previsit_session"

/*
 * ★ AI 配置表（P3 AI 能力中心）。
 *
 * ── 为什么是 KV 表而不是"一个字段一列" ──────────────────────────────────
 *   AI 配置项会随模型协议演进而增删（超时/并发/max_tokens/新参数…）。
 *   一列一项 ⇒ 每次加参数都要 DDL 变更 + 迁移。KV 表让"加配置项"
 *   只是往 `aiSettingSpecs()` 加一行（与 previsit 的 form_json 同一理由）。
 *
 * ── ★★ 为什么这张表里**不会有密钥** ─────────────────────────────────────
 *   brief §5.3 明确警告"把密钥写进库是倒退"。本设计里
 *   `ai.key_ref` 存的是**引用**（`env:名` / `file:路径`），
 *   由 `validateKeyRef()` **机制性**拒绝任何其它形状 ——
 *   所以即使有人误操作，也不可能把裸密钥写进这张表。
 *   该约束的验收断言在 AC-P2-7 / AC-P3-*（见 acceptance_ai.cj）。
 *
 * ⚠ `k` 是主键（配置项名唯一）；`v` 用 TEXT（endpoint/路径可能较长）。
 */
public let TABLE_AI_SETTING: String = "ai_setting"

/*
 * ★★ 分诊统计表（P4 新增，**第六类表**）。
 *
 * ── 为什么要一张专门的统计表（而不是看板时现算）──────────────────────────
 *   分诊（`POST /triage`）现在**只回结论、不留任何痕迹** ——
 *   于是"分诊命中率"这个指标在原设计里**无从计算**（要算就必须有历史）。
 *   ⇒ 记录每次分诊的**结论**，看板才可能给出真实分布。
 *
 * ── ★★ 它为什么**不含任何患者标识**（这是刻意的设计约束）────────────────
 *   本表**只有**：时间、结论码、是否危急、命中的科室名。
 *   **没有** patient_id / doctor_id / patient 任何联系方式 / 主诉原文。
 *
 *   理由：分诊是"还没挂号的人"在用的入口，它的输入是**主诉原文** ——
 *   那是最敏感的自由文本。一旦落库，它就成了"一份没有病历的病情记录"，
 *   而看板只需要**计数**。⇒ **按"只存得出指标所必需的最小集合"来建表**。
 *   📌 这也是"数据最小化"的朴素版本：不是"存了再脱敏"，而是**根本不存**。
 *
 * ⚠ 保留策略（与 previsit 同一纪律：不许无界增长）：
 *   `TRIAGE_STAT_TTL_DAYS` 天之前的行在每次写入时顺手清理（照 pruneTokens /
 *   pruneAttempts 的"顺手 prune"手法）。看板只看最近 14 天趋势 ⇒
 *   留 180 天足够，且能防"有人脚本刷分诊把表撑爆"。
 */
public let TABLE_TRIAGE_STAT: String = "triage_stat"

/*
 * ===================== P5：知识库（零向量库 RAG）=====================
 *
 * brief §5.5：「仓库**无 embedding、无向量、无余弦相似度**（全仓 grep 0 匹配）。
 * 仓颉侧要自己写：① 出站调 embedding 模型 ② 向量存 MySQL JSON
 * ③ **纯仓颉算余弦相似度**」。
 *
 * ★★ 两张表而不是一张，是**刻意的**：
 *   · `kb_doc`   —— 文档（**人维护的单位**：一篇须知/一条问答）
 *   · `kb_chunk` —— 切块（**检索的单位**：向量/关键词都作用在它上面）
 *   ⇒ 分成两层是因为"切块策略会变"（块大小/重叠），而**改策略不该动文档**；
 *     若合成一张表，每次调窗口都要重写文档行，且丢不掉旧块。
 *
 * ⚠⚠ 合规边界（第十份复查后新增，已写进 docs/Q6-合规决策记录.md）：
 *   知识库文档由**本院人员**维护（**文档本身不出站**），
 *   但**检索命中的片段会随 Prompt 出站给第三方模型** ⇒
 *   ⇒ 知识库里**不得放患者个人信息**。这一条**无法用代码保证**
 *     （文档是自由文本），所以：① 表注释写明；② 管理端写入时**拒绝明显的个人信息形态**；
 *     ③ Q6 记录里如实列为「仍需人工把关」的边界。
 */
public let TABLE_KB_DOC: String = "kb_doc"
public let TABLE_KB_CHUNK: String = "kb_chunk"

/*
 * ===================== 公告（2026-10-12 契约补齐）=====================
 *
 * 背景（实测缺口，不是"想加个功能"）：患者端首页有「医疗公告」区，
 *   但服务端**既没有表也没有端点** ⇒ 客户端只能无条件显示本地假公告
 *   （`PatientRepository.notices()` 直接返回 `MockPatientRepository.notices()`，
 *   实测在线模式下首页那两条公告是写死的）。这不是"少个 CRUD"，
 *   而是首页那一块**永远是假的**。
 *
 * ★ 为什么单开一张表，而不是复用 `kb_doc`：
 *   `kb_doc` 是**被检索**的运营资料（会被切块、可能被向量化、命中片段随 Prompt 出站），
 *   而公告是**给人看**的展示内容（不进检索、不出站、不需要切块）。
 *   两者读者、生命周期、合规边界都不同 ⇒ 合成一张表就会让
 *   "公告被当成知识库召回"（那正是本仓在 kb 上写死过的合规红线）。
 *
 * ⚠ `title` 唯一：公告最容易出的问题是**同一件事发了两条**
 *   （一条说 A、一条说 B），患者看到互相矛盾的两条。
 *   让"重名"在写入那一刻失败，比事后人工比对可靠 —— 与 `kb_doc.title` 同一条理由。
 * ⚠ `enabled` 而不是删除（同 department / kb_doc）：停用的公告**历史仍可解释**，
 *   直接 DELETE 会让"上周那条去哪了"变成不可回答的问题。
 * ⚠ `published_at`：公告需要能**预排期**（先写好，到点才出现）
 *   ⇒ 患者侧查询条件是 `enabled = 1 AND published_at <= now`，
 *     而不是只看 `enabled`。只看 enabled 会让"提前写好的公告"立刻曝光。
 */
public let TABLE_NOTICE: String = "notice"

/*
 * 全部业务表。
 * ⚠ rev.7 起内存 Store 已整体拆除 ⇒ 这张清单就是"库里有几张表"的唯一答案。
 */
public let ALL_TABLES: Array<String> = [
    TABLE_DEPARTMENT, TABLE_DOCTOR, TABLE_SCHEDULE,
    TABLE_APPOINTMENT, TABLE_PATIENT, TABLE_MEDICAL_RECORD,
    TABLE_AUTH_USER, TABLE_AUTH_TOKEN, TABLE_AUTH_ATTEMPT, TABLE_PREVISIT,
    TABLE_AI_SETTING, TABLE_TRIAGE_STAT,
    TABLE_KB_DOC, TABLE_KB_CHUNK, TABLE_NOTICE
]

/* ===================== DDL ===================== */

/*
 * 建表 DDL（幂等：全部 IF NOT EXISTS）。
 *
 * 设计要点：
 *  1. `schedule.version` —— 版本号（ADR-0001 §2.2）。每次成功扣减/归还 +1。
 *     ⚠ rev.3 起**不再是扣号的乐观锁前置条件**（实测它会让人少卖），
 *       改为服务「管理端并发编辑」的防覆盖 —— 见 domain_booking.cj tryDeductSlot 的长注释。
 *  2. `schedule.remain_num` —— 剩余号源。**扣减必须带 `remain_num > 0` 条件**，
 *     绝不出现负数（AC-2）。
 *  3. `schedule.work_date` —— 排班就诊日。管理员可一键顺延（改它）。
 *  4. ★ `appointment.visit_date` —— **就诊日快照**。挂号时从 schedule 拷一份，
 *     之后顺延排班**不影响已挂患者**（brief §2.3「顺延不串号」，AC-6）。
 *  5. `appointment.client_token` + 唯一索引 —— 幂等（AC-3）。唯一索引让"重复提交"
 *     由数据库兜底，而不是只靠应用层先查后写。
 *  6. 金额/编号一律 BIGINT，不用浮点（避免精度问题）。
 *
 * ⚠ VARCHAR 而非 TEXT 用于会建索引的列：MySQL 对 TEXT 建唯一索引要指定前缀长度。
 */
public let SCHEMA_DDL: Array<String> = [
    // ── 科室 ──────────────────────────────────────────────────────────────
    "CREATE TABLE IF NOT EXISTS department (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "name VARCHAR(64) NOT NULL, " +
    "code VARCHAR(32) NOT NULL, " +
    "location VARCHAR(128) NOT NULL DEFAULT '', " +
    "sort BIGINT NOT NULL DEFAULT 0, " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_department_code (code), " +
    /*
     * ★ 2026-10-09（基础数据域 CRUD）新增：**科室名唯一**。
     *
     * ⚠ 理由不是"看起来该唯一"，而是**有一个真调用方按名字查**：
     *   `triage.cj` 用 `SELECT ... FROM department WHERE name = ?` 判断
     *   "该科室是否可挂号"。同名会让这条判断**分裂**（命中哪行取决于存储顺序），
     *   而它恰好是"分诊推荐"与"排班列表"两处口径的连接点。
     * ⇒ 纪律要能被**数据库**兜底，而不是只靠应用层先查后写（那是 TOCTOU）。
     */
    "UNIQUE KEY uk_department_name (name)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 医生 ──────────────────────────────────────────────────────────────
    "CREATE TABLE IF NOT EXISTS doctor (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "name VARCHAR(64) NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "title VARCHAR(32) NOT NULL DEFAULT '', " +
    "specialty VARCHAR(255) NOT NULL DEFAULT '', " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "KEY idx_doctor_department (department_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 患者档案 ──────────────────────────────────────────────────────────
    // ⚠ 敏感个人信息（brief §9 R-4）：真实落地需个保法合规、实名、留存策略。
    //   原型阶段只存最小必要字段，**不存**身份证号明文。
    "CREATE TABLE IF NOT EXISTS patient (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "phone VARCHAR(32) NOT NULL, " +
    "name VARCHAR(64) NOT NULL, " +
    "gender VARCHAR(8) NOT NULL DEFAULT '', " +
    "birth_date VARCHAR(16) NOT NULL DEFAULT '', " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_patient_phone (phone)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 排班 / 号源 ★ 号源域 ──────────────────────────────────────────────
    // remain_num 才是防超卖的支柱（ADR-0001 §2.2）；version 只用于管理端防覆盖。
    "CREATE TABLE IF NOT EXISTS schedule (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "doctor_id BIGINT NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "work_date VARCHAR(16) NOT NULL, " +          // 就诊日 YYYY-MM-DD（可被顺延）
    "period VARCHAR(16) NOT NULL DEFAULT 'AM', " + // AM / PM
    "total_num BIGINT NOT NULL DEFAULT 0, " +
    "remain_num BIGINT NOT NULL DEFAULT 0, " +
    "version BIGINT NOT NULL DEFAULT 0, " +        // ← 版本号（rev.3 起不是扣号前置条件，用途见上）
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "KEY idx_schedule_doctor_date (doctor_id, work_date)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 挂号单 ★ 挂号域 ───────────────────────────────────────────────────
    // visit_date 是**快照**，不是外键——顺延排班不得改动已挂号单（AC-6）。
    "CREATE TABLE IF NOT EXISTS appointment (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "schedule_id BIGINT NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    "doctor_id BIGINT NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "visit_date VARCHAR(16) NOT NULL, " +          // ★ 就诊日快照
    "period VARCHAR(16) NOT NULL DEFAULT 'AM', " +
    "seq_no BIGINT NOT NULL DEFAULT 0, " +         // 就诊序号
    "status VARCHAR(16) NOT NULL DEFAULT 'booked', " + // booked / cancelled / done
    /*
     * ★ 幂等键。**可空**，且退号时会被置为 NULL（2026-10-07 修）。
     *
     * 为什么必须可空：`client_token` 是**客户端自己**生成的字符串，
     *   单一旦被取消，那个 token 就该**释放掉**、允许下一次挂号再用（见 book/cancel 注释）。
     *   但唯一索引 (patient_id, client_token) 会一直占着已取消那行 ⇒
     *   重挂时 INSERT 撞唯一键 → **500**（实测复现）。
     *
     * 为什么用 NULL 而不是空串：**MySQL 的唯一索引允许多个 NULL**（NULL != NULL），
     *   于是"置 NULL 即释放"天然成立，可以有多张已取消的单。
     *   若用空串，第二个被取消的单就会撞 (patient_id, '') —— 空串在唯一索引里是**相等**的。
     */
    "client_token VARCHAR(64) NULL DEFAULT NULL, " + // ← 幂等键（退号置 NULL）
    /*
     * ★ 退号时**号源是否已归还**（2026-10-07 增）。
     *
     * 为什么要落库：`cancel()` 是幂等的，第二次调用要走"已取消则直接返回"的快路径。
     * 原实现在那条路径上**无条件返回 `Cancelled`** —— 而 `Cancelled` 的语义是
     * "已取消 **且号已归还**"。于是当第一次退号因 `remain_num == total_num`
     * （管理员重置过号源）而没能归还时：
     *   · 第 1 次退号 → `SlotNotRestored` + 告警（诚实）
     *   · 第 2 次退号（用户重试）→ `Cancelled`，**告警消失**
     * 实测复现。运维告警被一次无关的重试抹掉，而号源确实还挂着。
     * 落库后，幂等路径就能**如实**返回上次的真实结果。
     *
     * 默认 1（已归还）：历史数据与"挂号但未退号"的单都不涉及归还问题。
     */
    "slot_restored TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "cancelled_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    // 幂等由数据库兜底，但**必须按患者隔离**：
    // ⚠ 原先是 `UNIQUE (client_token)`（全局）—— 而 client_token 是**客户端自己**生成的
    //   字符串（客户端契约就是 "booking-1" 这类），于是不同患者用同一个 token 会互相
    //   撞车：患者 B 提交 A 用过的 token 会命中 A 的单（跨患者数据泄露）。
    //   实测复现过。改成 (patient_id, client_token)：同患者不可重复，跨患者互不影响。
    "UNIQUE KEY uk_appointment_patient_token (patient_id, client_token), " +
    "KEY idx_appointment_patient (patient_id, status), " +
    "KEY idx_appointment_schedule (schedule_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 电子病历（七段式，brief §2.1；P0 只建表）──────────────────────────
    "CREATE TABLE IF NOT EXISTS medical_record (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "appointment_id BIGINT NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    "doctor_id BIGINT NOT NULL, " +
    "chief_complaint TEXT NOT NULL, " +   // 主诉
    "present_illness TEXT NOT NULL, " +   // 现病史
    "past_history TEXT NOT NULL, " +      // 既往史
    "allergy_history TEXT NOT NULL, " +   // 过敏史
    "physical_exam TEXT NOT NULL, " +     // 体格检查
    "diagnosis TEXT NOT NULL, " +         // 诊断
    "treatment TEXT NOT NULL, " +         // 处理意见
    "status VARCHAR(16) NOT NULL DEFAULT 'draft', " + // draft / locked
    /*
     * ★ 最后修改人（P4 增）。**为什么病历必须有它**：
     *   病历最要紧的属性之一是"**谁写的**" —— 没有它，"锁定"只锁住了内容，
     *   锁不住责任（解锁后谁改的、谁该为这版负责，都无从查）。
     *   ⚠ 本轮只记"最后修改人"，**没有**完整修订历史表（谁在第几版改了什么）——
     *     那属后续，已写进 P4-HANDOFF 的未做清单。
     */
    "updated_by BIGINT NOT NULL DEFAULT 0, " +
    /*
     * ★ 预问诊**来源痕迹**（2026-10-14 增，改进 1）。
     *
     * 为什么不能只靠前端在输入框里拼一个「患者自述：」前缀：
     *   锁定/解锁之后就再也分不清哪一段是患者说的、哪一段是医生写的 ——
     *   而"这段谁写的"是病历的可追溯性要求（同一份病历可能先被自述预填、再被医生改写）。
     *   存 JSON：`{"session_id":"…","sections":["chief_complaint",…],"at":<epoch 秒>}`；
     *   `sections` 由 `saveDraft` 里**实际写入的那些段**（同一个 map）推导，不另算一遍。
     * ⚠ 类型选 VARCHAR(1024) 而不是 TEXT：本列需要默认值（老库 ALTER 时也要能补列），
     *   而 MySQL **不允许** TEXT 带 DEFAULT（MariaDB 允许，但本项目 DSN 写的是 mysql://，
     *   不值得为一个约 260 字符的 JSON 引入"只在某个引擎上才建得出表"的差异）。
     */
    "previsit_ref VARCHAR(1024) NOT NULL DEFAULT '', " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_record_appointment (appointment_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ⚠ 这里曾有一张 `booking_idem`（挂号幂等登记表）—— 2026-10-07 **连表带实现一起删除**。
    //   理由：幂等已由 `appointment` 上的 `(patient_id, client_token)` 唯一索引
    //   完整保证（**数据库级**保证，比应用级登记表更硬），而该表在生产路径上
    //   从未被调用过（只有验收测试在测它 ⇒ 测的是一条生产不走的路）。
    //   详细取舍见 ADR-0001 §7 第 7 条。
    //   📌 迁移注意：若目标库是旧库，`migrateSchema()` 会 DROP 掉这张遗留表。

    // ── 鉴权账号（P1 令牌体系）───────────────────────────────────────────
    // 一个账号 = 一个登录身份。三端角色（patient/doctor/admin）共用本表，
    // 用 role 区分；`ref_id` 指向该角色对应的业务实体
    // （患者 → patient.id，医生 → doctor.id，管理员 → 0 表示无业务实体）。
    //
    // ⚠ 为什么不合进 patient 表：医生与管理员也要登录，而他们不是患者；
    //   把三者塞进一张表会让"谁是患者"这个判定变得依赖 role 字段，
    //   而 role 是鉴权属性、不是业务属性。分开后 patient 表保持纯业务语义。
    "CREATE TABLE IF NOT EXISTS auth_user (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "login_name VARCHAR(64) NOT NULL, " +      // 患者用手机号；医生/管理员用工号
    "role VARCHAR(16) NOT NULL, " +            // patient / doctor / admin
    "ref_id BIGINT NOT NULL DEFAULT 0, " +     // 对应业务实体 id
    "display_name VARCHAR(64) NOT NULL DEFAULT '', " +
    "pw_salt VARCHAR(64) NOT NULL, " +         // 16 字节盐的 hex
    "pw_hash VARCHAR(128) NOT NULL, " +        // 32 字节摘要的 hex
    "pw_iter BIGINT NOT NULL DEFAULT 0, " +    // 迭代数（随记录走，便于将来升级）
    "status VARCHAR(16) NOT NULL DEFAULT 'active', " +  // active / disabled
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_auth_user_login (login_name)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 鉴权令牌（P1 令牌体系）───────────────────────────────────────────
    // ⚠ 刻意**不叫** `tokens`：搬迁前的内存 Store 已占用该表名（mysql_store.cj:891）。
    // 令牌是 64 个十六进制字符（32 字节随机），用 VARCHAR(64) 主键。
    // 服务端存 token → user 映射 ⇒ **不是无状态 JWT**，所以"停用账号"能立即踢下线。
    "CREATE TABLE IF NOT EXISTS auth_token (" +
    "token VARCHAR(64) NOT NULL, " +
    "user_id BIGINT NOT NULL, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "expires_at BIGINT NOT NULL DEFAULT 0, " +
    "last_renew_at BIGINT NOT NULL DEFAULT 0, " +  // 滑动续期节流用
    /*
     * ★ 设备标识（P1 收尾项 ②：令牌按设备管理）。
     *
     * `device_id` 是**客户端自报**的稳定标识（如设备安装 id / 浏览器指纹）；
     * `device_name` 是给人看的（如 "iPhone 15" / "Chrome on Windows"）。
     * 两者都由客户端在登录时通过请求头带上（见 http_app.cj 的 deviceOf()）。
     *
     * ⚠ 安全边界（必须写明）：**这两个字段是客户端自报的，不可信**。
     *   它们只用做"会话列表的展示与区分"，**绝不**用于授权判定 ——
     *   否则伪造一个 device_id 就能冒充别人的会话。
     *   真正的授权依据始终是 `token` 本身（见 principalByToken）。
     *
     * 为什么落库而不是内存：令牌本来就是直接 SQL 持久化的（ADR §4.2），
     *   设备信息跟着令牌走才能"重启服务后仍能列出会话"。
     */
    "device_id VARCHAR(64) NOT NULL DEFAULT '', " +
    "device_name VARCHAR(64) NOT NULL DEFAULT '', " +
    "last_seen_at BIGINT NOT NULL DEFAULT 0, " +   // 最近一次使用（列表排序用）
    "PRIMARY KEY (token), " +
    "KEY idx_auth_token_user (user_id), " +
    "KEY idx_auth_token_expires (expires_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 登录失败计数 / 锁定（P1 安全加固）────────────────────────────────
    /*
     * 一行 = 一个登录名（**哈希后**）的连续失败状态。
     *
     * 列语义：
     *   login_hash   登录名的 SHA-256 十六进制（见 auth_repo.loginNameHash）
     *   fail_count   观察窗口内的**连续**失败次数（成功登录即清零）
     *   window_start 本轮观察窗口起点
     *   last_fail_at 最近一次失败时刻（锁定从这里起算）
     *
     * ⚠ 为何开 `idx_auth_attempt_lastfail`：清理过期行按 last_fail_at 扫，
     *   否则表只增不减（搬迁前 tokens 表"只增不减"就是这个坑，见 auth_repo.pruneTokens）。
     */
    "CREATE TABLE IF NOT EXISTS auth_login_attempt (" +
    "login_hash VARCHAR(64) NOT NULL, " +
    "fail_count BIGINT NOT NULL DEFAULT 0, " +
    "window_start BIGINT NOT NULL DEFAULT 0, " +
    "last_fail_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (login_hash), " +
    "KEY idx_auth_attempt_lastfail (last_fail_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /*
     * ── 预问诊会话（P2）────────────────────────────────────────────────────
     * `form_json` 用 JSON 列存问诊单（加问诊项不必改 DDL，见 TABLE_PREVISIT 注释）。
     * ⚠ `patient_id` 上有索引：`find` 永远带 `patient_id` 条件
     *   （只按 id 查会让患者 A 读到 B 的问诊单 —— 这是安全要求，不是性能要求）。
     * ⚠ **不建**指向 `patient` 的外键：与本 schema 其它表一致（见 hResetAll 的说明），
     *   让测试可以独立清表。
     */
    "CREATE TABLE IF NOT EXISTS triage_stat (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "source VARCHAR(16) NOT NULL DEFAULT 'rules', " +   // rules / model（接模型后区分）
    "reason_code VARCHAR(32) NOT NULL DEFAULT '', " +
    "red_flag TINYINT NOT NULL DEFAULT 0, " +
    "department VARCHAR(64) NOT NULL DEFAULT '', " +
    "truncated TINYINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "KEY idx_triage_stat_at (created_at), " +
    "KEY idx_triage_stat_reason (reason_code)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS ai_setting (" +
    "k VARCHAR(64) NOT NULL, " +
    "v TEXT NOT NULL, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (k)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS previsit_session (" +
    "id VARCHAR(64) NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    /*
     * ★ 绑定的挂号单（2026-10-14 增，改进 1）。`0` = 尚未绑定
     *   （患者开流作答时还没有挂号，或挂号请求没带 `previsit_id`）。
     *   ⚠ 为什么必须由**服务端**存这一段关系：此前"患者答的问诊单"与
     *   "医生看的这次就诊"之间只有客户端本机 `SessionStore` 里一个 id ——
     *   换台设备、或医生端在另一台机器上打开，这条链路就断了
     *   （而且"提交过会话 id"≠"医生看得到"）。绑定后医生可按**挂号单**取摘要。
     */
    "appointment_id BIGINT NOT NULL DEFAULT 0, " +
    "turn BIGINT NOT NULL DEFAULT 0, " +
    "form_json TEXT NOT NULL, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "KEY idx_previsit_patient (patient_id, updated_at), " +
    "KEY idx_previsit_appointment (appointment_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* ===================== P5 知识库 DDL（拼在 SCHEMA_DDL 上）===================== */

/*
 * ⚠ 为什么单独一个数组而不是直接塞进 `SCHEMA_DDL`：
 *   那一段很长（14 张表），P5 的表有**自己的设计说明**（向量存储格式、切块与文档分层、
 *   合规边界），塞进去会把它淹掉。分开写、末尾拼接 —— 建表入口一处不改。
 *   📌 与 `registerP4Routes` / `registerBaseRoutes` 同一手法：**内容分文件，注册集中**。
 */
public let KB_SCHEMA_DDL: Array<String> = [
    /*
     * 知识库文档（**人维护的单位**）。
     *
     * ⚠ `title` 加唯一键：知识库最容易出的问题是**同一主题写了两份互相矛盾的文档**，
     *   而检索会把两份都召回 ⇒ 模型看到矛盾内容，输出不可预测。
     *   让"重名"在写入那一刻失败，比事后人工比对可靠。
     * ⚠ `enabled` 而不是删除：文档停用后**历史检索记录仍可解释**（同 department 的理由）。
     */
    "CREATE TABLE IF NOT EXISTS kb_doc (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "title VARCHAR(128) NOT NULL, " +
    "category VARCHAR(32) NOT NULL DEFAULT '', " +
    "body TEXT NOT NULL, " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "updated_by BIGINT NOT NULL DEFAULT 0, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_kb_doc_title (title), " +
    "KEY idx_kb_doc_category (category)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /*
     * 知识库切块（**检索的单位**）。
     *
     * `embedding` 存 **JSON 数组**（复刻 brief §5.5 说的参考系统 `kb_chunk.embedding` 做法）。
     * ⚠ 为什么用 JSON 而不是 BLOB/float 表：
     *   · 本项目**没有向量库**，也不该为几千个块引入一个（brief §5.5 的判断）；
     *   · JSON 让**纯仓颉**能直接解析成 `Array<Float64>` 算余弦（brief 明确要求）；
     *   · 代价如实记下：**全表扫描 + 逐行 JSON 解析**，几千块可接受，上万块要降维/分片。
     * ⚠ `embedding` 允许 NULL：**关键词检索不需要向量**（brief §5.5 的降级路径）。
     *   这正是"零向量库"的关键 —— 没有 embedding 服务时系统**照样能用**。
     * ⚠ 唯一键 `(doc_id, seq)`：同一文档的同一个块号只能有一行 ⇒
     *   **重新切块时按 (doc_id, seq) upsert**，不会留下旧块的幽灵行。
     */
    "CREATE TABLE IF NOT EXISTS kb_chunk (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "doc_id BIGINT NOT NULL, " +
    "seq BIGINT NOT NULL, " +
    "content TEXT NOT NULL, " +
    "chars BIGINT NOT NULL DEFAULT 0, " +
    "embedding TEXT NULL, " +
    "embedded_at BIGINT NOT NULL DEFAULT 0, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_kb_chunk_doc_seq (doc_id, seq), " +
    "KEY idx_kb_chunk_doc (doc_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* ===================== 公告 DDL（拼在 SCHEMA_DDL 上）===================== */

/*
 * ⚠ 与 `KB_SCHEMA_DDL` 同一手法：**单独一个数组 + 末尾拼接**，建表入口一处不改
 *   （`ensureSchema` / `allSchemaDdl` 各多一个循环）。
 *   理由也一样：本表有自己的设计说明（见 `TABLE_NOTICE` 上方），
 *   塞进那个 14 张表的长数组会被淹掉。
 *
 * ⚠ 新表**不需要** `migrateSchema`：那是给"改了**既有**表结构"用的
 *   （`CREATE TABLE IF NOT EXISTS` 对已存在的表完全无效）。
 *   这里是从无到有，`ensureSchema` 在 serve / check-db / accept 启动路径上
 *   都会跑，存量库启动时自动补建。
 */
public let NOTICE_SCHEMA_DDL: Array<String> = [
    "CREATE TABLE IF NOT EXISTS notice (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "title VARCHAR(128) NOT NULL, " +
    "body TEXT NOT NULL, " +
    "category VARCHAR(32) NOT NULL DEFAULT '通知', " +
    "sort BIGINT NOT NULL DEFAULT 0, " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "published_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_by BIGINT NOT NULL DEFAULT 0, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_notice_title (title), " +
    /*
     * 患者侧查询固定是「enabled = 1 AND published_at <= now ORDER BY sort, published_at DESC」
     * ⇒ 索引按这条语句的前两列建。列表本身很短（几十条），
     * 不加这个索引也能跑，但"查询形状与索引一致"能让将来公告变多时不必回头改。
     */
    "KEY idx_notice_visible (enabled, published_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* ===================== AI 模型配置 DDL（拼在 SCHEMA_DDL 上）===================== */

/*
 * ★★ 为什么要有这张表（2026-10-14，管理台需求）：
 *
 *   在这之前，AI 出站所需的四件事（endpoint / model / max_tokens / key_ref）
 *   全是 `ai_setting` 里的**单份 KV** —— 也就是"全系统只有一个模型"。
 *   而真实需求（管理台「AI 模型配置」页，见 docs/ADMIN-WEB.md）是
 *   **多条命名配置**：默认对话模型 + 默认向量模型，各自有类型、提供方、
 *   接口地址、模型名、温度、max_tokens、启停。
 *
 * ⚠ 为什么**新建一张表**而不是继续往 `ai_setting` 塞 KV：
 *   ① "多条"这件事 KV 表达不了（`ai.model.1.model` 这种键名会立刻失控）；
 *   ② 每条配置的**字段有类型与范围**（温度 0..2、max_tokens 64..8192、kind 枚举），
 *      用列表达才能在**写入那一刻**被 SQL 约束 + 校验拦住；
 *   ③ `is_default` 需要"每个 kind 最多一条"这样的**集合级不变量**，
 *      KV 里没有任何地方能查这个。
 *
 * ⚠ 与 `ai_setting` 的关系（**刻意保留旧表，不迁移不删除**）：
 *   · `ai.enabled` 仍是**总开关**（一次关掉全部模型，运维在故障时的第一反应）；
 *   · 旧 KV 的 `ai.endpoint`/`ai.model`/`ai.max_tokens` 仍被读取，作为
 *     **没有任何默认模型时**的回落（存量库升级后不会突然"AI 不可用"）；
 *   · 新表有默认模型时**优先用新表**（见 ai_settings.cj 的 aiRuntimeResolve）。
 *   📌 一般化：**新机制上线时给旧机制留一条"读得到"的回退路**，
 *     这样升级顺序（先升级服务端、后建配置）不会造成一个"静默不可用"的窗口。
 *
 * ⚠ `name` 加唯一键：运维要靠名字认配置（"默认对话模型"），重名会让
 *   "我改的到底是哪条"变成一个无法回答的问题（同 kb_doc.title 的理由）。
 * ⚠ `enabled` 而不是删除：停用后**历史调用记录仍可解释**（同部门/医生的理由）。
 * ⚠ `key_ref` 存的是**引用**（`env:名` / `file:路径`），**绝不是密钥本体**
 *   —— 与 `ai_setting.ai.key_ref` 同一条纪律（brief §5.3），
 *   由 `aiModelValidate` 复用 `validateKeyRef` 机制性保证。
 */
public let AI_MODEL_SCHEMA_DDL: Array<String> = [
    "CREATE TABLE IF NOT EXISTS ai_model (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "name VARCHAR(64) NOT NULL, " +
    /* CHAT / EMBEDDING —— 两种出站协议不同（见 ai_model.cj 的 aiModelKindOf）。 */
    "kind VARCHAR(16) NOT NULL, " +
    /* 提供方只是**给人看的标签**（百练/OpenAI/自建），不参与出站逻辑。 */
    "provider VARCHAR(64) NOT NULL DEFAULT '', " +
    "base_url VARCHAR(512) NOT NULL, " +
    "model VARCHAR(128) NOT NULL, " +
    /*
     * ⚠ 温度用 DOUBLE 而不是 KV 里的字符串：它要参与**范围校验**（0..2），
     *   而字符串列在数据库里没有任何东西能拦住 `temperature = "abc"`。
     */
    "temperature DOUBLE NOT NULL DEFAULT 0.3, " +
    "max_tokens BIGINT NOT NULL DEFAULT 2048, " +
    "key_ref VARCHAR(512) NOT NULL DEFAULT '', " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "is_default TINYINT NOT NULL DEFAULT 0, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_by BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_ai_model_name (name), " +
    /* 解析"某 kind 的默认模型"走的正是这个索引形状。 */
    "KEY idx_ai_model_active (kind, enabled, is_default)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* ===================== 建表入口 ===================== */

/*
 * 幂等建表：逐条执行 SCHEMA_DDL。
 *
 * 为什么不用框架 `ensureTable(name, columns)`：它的入参是**列定义片段**，
 * 表达不了唯一索引、复合索引与 ENGINE/CHARSET；而幂等（AC-3）恰恰依赖唯一索引。
 * 所以这里直接用完整 DDL 文本，与搬迁前 mysql_store.cj:384 同一写法。
 *
 * 返回：实际执行的语句数（便于启动日志与测试断言）。
 */
public func ensureSchema(db: DbBackend): Int64 {
    var n: Int64 = 0
    for (sql in SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    /*
     * ★ P5：知识库两张表（各自一个数组，理由见 KB_SCHEMA_DDL 上方注释）。
     * ⚠ 拼接而不是并进 SCHEMA_DDL：**建表入口一处不改**，
     *   但"有哪些表"仍然只有一处可数（便于 selftest 与 doc-counts 对账）。
     */
    for (sql in KB_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    /* ★ 公告表（同上：单独数组、末尾拼接）。 */
    for (sql in NOTICE_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    /* ★ AI 模型配置表（2026-10-14 管理台；同上：单独数组、末尾拼接）。 */
    for (sql in AI_MODEL_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    return n
}

/*
 * ★★ **全部** DDL 的合并视图 —— 任何"遍历所有 DDL"的地方都必须用它。
 *
 * ⚠⚠ 这个函数是 2026-10-09 补的，起因是一个**真实的漏检**：
 *   P5 把知识库 DDL 单独放进 `KB_SCHEMA_DDL`（为了让 P5 的设计说明独立、
 *   不被 14 张表的长数组淹掉），`ensureSchema` **两处都遍历**了 —— 建表是对的。
 *   但 `main.cj` 的 selftest 有 **4 处**只遍历 `SCHEMA_DDL`
 *   ⇒ 自检报「表 kb_doc 没有对应 DDL」，而**实际上表建出来了**。
 *
 *   ⇒ 那次失败**有价值**：它证明「每张业务表都有 DDL」这条自检**确实在工作**
 *     （它抓到了自己遍历不全），但也暴露了**遍历点分散**这个结构问题 ——
 *     下次再加表，很可能又只改一处。
 *   ⇒ 修法不是"把 P5 的表塞回大数组"（那会丢掉分文件的好处），
 *     而是**把「全部 DDL」变成一个不可绕过的名字**。自检只认它 ⇒
 *     以后新增任何 DDL 数组，只要并进这里就自动被覆盖。
 *   📌 一般化：**「有哪些」这件事只能有一处答案** —— 否则迟早有地方少数。
 *
 * ⚠ 用 `ArrayList` 拼（仓颉的 `Array` **不支持 `+`**：实测报
 *   `invalid binary operator '+' on type 'Struct-Array<Struct-String>'`）。
 */
public func allSchemaDdl(): Array<String> {
    let out = ArrayList<String>()
    for (sql in SCHEMA_DDL) {
        out.add(sql)
    }
    for (sql in KB_SCHEMA_DDL) {
        out.add(sql)
    }
    for (sql in NOTICE_SCHEMA_DDL) {
        out.add(sql)
    }
    for (sql in AI_MODEL_SCHEMA_DDL) {
        out.add(sql)
    }
    return out.toArray()
}

/*
 * 判定某表是否属于「号源/挂号的**业务状态**」，即走直接 SQL 的那两张。
 * 用途：ADR-0001 §4.3 的范围检查 —— 新增业务表若误入此域，测试应报错。
 */
public func isBookingDomainTable(name: String): Bool {
    for (t in BOOKING_DOMAIN_TABLES) {
        if (t == name) {
            return true
        }
    }
    return false
}

/*
 * 判定某表是否属于**鉴权域**（auth_user / auth_token）。
 *
 * 与号源域同理：鉴权表也走直接 SQL（见 auth_repo.cj），
 * 但它们不是号源/挂号业务状态，所以与 BOOKING_* 分开列 ——
 * 这样"某张表归谁管"永远能从一个函数问出来，而不是靠读代码猜。
 */
public func isAuthTable(name: String): Bool {
    return name == TABLE_AUTH_USER || name == TABLE_AUTH_TOKEN || name == TABLE_AUTH_ATTEMPT
}

/*
 * 判定某表是否由 `BookingRepo` 写入（= 号源/挂号**业务状态**表）。
 * 用途：ADR-0001 §4.3「范围锁死」的口径 —— 直接 SQL 只准落在这**两张**表上。
 *
 * ⚠ 2026-10-07 起本函数等价于 `isBookingDomainTable`：原先它还要
 *   `|| isBookingInfraTable(name)`（那一层对应已删除的 `booking_idem` 表），
 *   而该表已连同实现一起删除（见文件头 / ADR §7 第 7 条）。
 *   函数名保留，是因为"谁拥有这张表"这个**问题**与调用点都还在 ——
 *   将来若真需要第二层幂等基础设施，仍然从这里扩。
 */
public func isBookingOwnedTable(name: String): Bool {
    return isBookingDomainTable(name)
}

/* ===================== 迁移 ===================== */

/*
 * 幂等迁移：把旧库里的 `uk_appointment_client_token`（全局唯一）换成
 * `uk_appointment_patient_token`（按患者唯一）。
 *
 * ★ 为什么必须有这一步：`SCHEMA_DDL` 全是 `CREATE TABLE IF NOT EXISTS` ——
 *   表**已经存在**时 DDL 整体被跳过，所以**改了 DDL 对存量库没有任何效果**。
 *   开发期我就是这样漏掉了几张表的口径更新（改完 DDL 以为生效了）。
 *   凡是"改了既有表结构"都必须配一段显式迁移，否则新库对、老库错。
 *
 * 做法（先查 information_schema 再动手，可重复执行）：
 *   ① 旧索引存在 → DROP；
 *   ② 新索引不存在 → CREATE UNIQUE。
 *
 * ⚠ 顺序很关键：**先**加新索引再删旧的会更安全（避免中间窗口无约束），
 *   但 `(patient_id, client_token)` 在有历史重复数据时会建失败；
 *   所以这里保持"先删后加"，并把失败**明确抛出来**而不是静默忽略 ——
 *   静默失败会留下一个"没有唯一约束"的库，幂等就断了一半。
 */
public func migrateSchema(db: DbBackend): Int64 {
    var done: Int64 = 0

    /*
     * ★ P4：`medical_record.updated_by`（存量库补列）。
     *
     * ⚠ 为什么必须显式迁移：`CREATE TABLE IF NOT EXISTS` 对**已存在**的表
     *   **完全无效** —— 老库上这张表早就建好了，DDL 里加列不会生效。
     *   实测症状：`Unknown column 'updated_by' in 'SELECT'`（整个病历域全挂）。
     *   📌 这就是 `migrateSchema` 存在的理由（原注释里已写明"存量库靠 DDL 改不动"）。
     */
    let hasUpdatedBy = db.query(
        "SELECT COUNT(*) FROM information_schema.COLUMNS " +
        "WHERE table_schema = DATABASE() AND table_name = 'medical_record' " +
        "AND column_name = 'updated_by'",
        Array<DbValue>())
    if (hasUpdatedBy.rowCount() > 0 && hasUpdatedBy.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE medical_record ADD COLUMN updated_by BIGINT NOT NULL DEFAULT 0",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ★ 2026-10-09：`department.name` 补唯一键（存量库）。
     *
     * ⚠ 与上面 medical_record.updated_by 同理：`CREATE TABLE IF NOT EXISTS`
     *   对已存在的表**完全无效**，老库上这张表早建好了 ⇒ 必须在迁移里显式加。
     * ⚠ 加之前**先查重名**：若有重名，ALTER 会失败并让整个 check-db 报错。
     *   重名是**数据问题**，不是结构问题 ⇒ 这里给出**可执行的处置**（列出重名），
     *   而不是抛一个"Duplicate entry"让人猜。若确实有重名，我们**不自动改名**
     *   （改名可能改变分诊含义，属人工决策），只报告。
     */
    let nameIdx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'department' " +
        "AND index_name = 'uk_department_name'",
        Array<DbValue>())
    if (nameIdx.rowCount() > 0 && nameIdx.getInt(0, 0) == 0) {
        let dups = db.query(
            "SELECT COUNT(*) FROM (SELECT name FROM department GROUP BY name " +
            "HAVING COUNT(*) > 1) t", Array<DbValue>())
        if (dups.rowCount() > 0 && dups.getInt(0, 0) > 0) {
            throw Exception("department 表存在 ${dups.getInt(0, 0)} 组**重名科室**，" +
                "无法加唯一键 uk_department_name。\n" +
                "  处置：先人工合并/改名（分诊按科室名查询，重名会让推荐结果不确定）：\n" +
                "    SELECT name, COUNT(*) c FROM department GROUP BY name HAVING c > 1;")
        }
        db.exec("ALTER TABLE department ADD UNIQUE KEY uk_department_name (name)",
                Array<DbValue>())
        done = done + 1
    }

    let oldIdx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'appointment' " +
        "AND index_name = 'uk_appointment_client_token'",
        Array<DbValue>())
    if (oldIdx.rowCount() > 0 && oldIdx.getInt(0, 0) > 0) {
        db.exec("ALTER TABLE appointment DROP INDEX uk_appointment_client_token",
                Array<DbValue>())
        done = done + 1
    }

    let newIdx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'appointment' " +
        "AND index_name = 'uk_appointment_patient_token'",
        Array<DbValue>())
    if (newIdx.rowCount() > 0 && newIdx.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE appointment " +
                "ADD UNIQUE KEY uk_appointment_patient_token (patient_id, client_token)",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ③ 补 `appointment.slot_restored` 列（2026-10-07 增）。
     *    `CREATE TABLE IF NOT EXISTS` 对已有表**完全不生效**，
     *    所以新增列必须显式 ALTER，否则老库上这一列永远不存在，
     *    而查询它就会报 Unknown column —— 那比静默降级更"响"，但同样是坏掉。
     */
    let hasCol = db.query(
        "SELECT COUNT(*) FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'appointment' " +
        "AND column_name = 'slot_restored'",
        Array<DbValue>())
    if (hasCol.rowCount() > 0 && hasCol.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE appointment " +
                "ADD COLUMN slot_restored TINYINT NOT NULL DEFAULT 1",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ④ `client_token` 改为可空（2026-10-07 增）。
     *    两个动作、顺序不能反：
     *      ① 先把历史的空串归一成 NULL（否则 NULL 与 '' 两种"空"混在一起）
     *      ② 再把列改成 NULL 可空
     *    ⚠ 只改 DDL 不改历史数据的话，"空串"行仍会在唯一索引里互相冲突 ——
     *      这正是本轮修的那个 500 的同一类原因，别在新库上重新引入一遍。
     */
    let colNullable = db.query(
        "SELECT IS_NULLABLE FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'appointment' " +
        "AND column_name = 'client_token'",
        Array<DbValue>())
    if (colNullable.rowCount() > 0 && colNullable.getString(0, 0) == "NO") {
        db.exec("UPDATE appointment SET client_token = NULL WHERE client_token = ''",
                Array<DbValue>())
        db.exec("ALTER TABLE appointment " +
                "MODIFY COLUMN client_token VARCHAR(64) NULL DEFAULT NULL",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ⑤ ★ 释放**已取消**单占用的幂等键（2026-10-07 增）。
     *
     * 这是上面 ④ 的**补齐**，漏了它就会留下一个很隐蔽的坑：
     *   "退号时置 NULL" 只对**迁移之后**发生的退号生效；
     *   迁移**之前**就已经取消的单，其 client_token 仍是原值。
     *   于是 (patient_id, client_token) 唯一索引仍被那张老单占着，
     *   患者用同一个 token 重挂 ⇒ INSERT 撞唯一键 ⇒ **500**。
     *   实测复现（库里能看到 status='cancelled' 且 client_token='reuse-me' 的老行）。
     *
     * ⚠ 教训：改语义时不能只管"以后"，**已经躺在库里的数据也要一起归位** ——
     *   否则新代码 + 老数据 = 只在特定历史路径上炸，最难查。
     */
    let staleCancelled = db.exec(
        "UPDATE appointment SET client_token = NULL " +
        "WHERE status = 'cancelled' AND client_token IS NOT NULL",
        Array<DbValue>())
    if (staleCancelled > 0) {
        done = done + 1
    }

    /*
     * ⑥ 给 `auth_token` 补设备字段（P1 收尾项 ②）。
     *    同 ⑤ 的理由：`CREATE TABLE IF NOT EXISTS` 对**已有表**完全不生效，
     *    所以加列必须显式 ALTER，否则老库上查这些列会报 Unknown column。
     *    四列一起补；用 information_schema 判断，可重复执行。
     */
    let devCols = db.query(
        "SELECT COUNT(*) FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'auth_token' " +
        "AND column_name IN ('device_id', 'device_name', 'last_seen_at')",
        Array<DbValue>())
    if (devCols.rowCount() > 0 && devCols.getInt(0, 0) < 3) {
        db.exec("ALTER TABLE auth_token " +
                "ADD COLUMN device_id VARCHAR(64) NOT NULL DEFAULT '', " +
                "ADD COLUMN device_name VARCHAR(64) NOT NULL DEFAULT '', " +
                "ADD COLUMN last_seen_at BIGINT NOT NULL DEFAULT 0",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ⑦ ★ DROP 掉遗留的 `booking_idem` 表（2026-10-07，随"删死代码"决策）。
     *
     * 同样地：`CREATE TABLE IF NOT EXISTS` 只管"建"，**不管"删"** ——
     * 老库里那张表不会因为我们把 DDL 删了而消失。不显式 DROP 的话：
     *   · `selftest` 断言"ALL_TABLES 与实际表零差集"会**失败**（库里多一张）；
     *   · 更糟的是留下一个"看起来还在用"的表，下一个人会以为幂等还走它。
     *
     * ⚠ 这是**唯一**一处 `DROP TABLE`。它删的是一张**从不存业务数据**的
     *   幂等登记表，且其功能已由 `(patient_id, client_token)` 唯一索引覆盖
     *   （见 ADR-0001 §7 第 7 条），所以不丢任何业务事实。
     */
    let staleIdem = db.query(
        "SELECT COUNT(*) FROM information_schema.tables " +
        "WHERE table_schema = DATABASE() AND table_name = 'booking_idem'",
        Array<DbValue>())
    if (staleIdem.rowCount() > 0 && staleIdem.getInt(0, 0) > 0) {
        db.exec("DROP TABLE booking_idem", Array<DbValue>())
        done = done + 1
    }

    /*
     * ⑧ ★ 2026-10-14（改进 1）：`previsit_session.appointment_id` + 索引（存量库）。
     *
     * 同 ⑥/⑦ 的理由：`CREATE TABLE IF NOT EXISTS` 对**已有表**完全不生效 ——
     * 老库上 `previsit_session` 早建好了，DDL 里加列不会生效，而代码一旦
     * 按 `appointment_id` 查/写就会报 `Unknown column`（整个预问诊域挂掉）。
     * ⚠ 列与索引**分两步判断**：老库可能已经有人手工加了列却没加索引
     *   （而"按挂号单取摘要"是走索引的查询），所以两个条件各自独立。
     */
    let hasPvAppt = db.query(
        "SELECT COUNT(*) FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'previsit_session' " +
        "AND column_name = 'appointment_id'",
        Array<DbValue>())
    if (hasPvAppt.rowCount() > 0 && hasPvAppt.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE previsit_session " +
                "ADD COLUMN appointment_id BIGINT NOT NULL DEFAULT 0",
                Array<DbValue>())
        done = done + 1
    }
    let pvApptIdx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'previsit_session' " +
        "AND index_name = 'idx_previsit_appointment'",
        Array<DbValue>())
    if (pvApptIdx.rowCount() > 0 && pvApptIdx.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE previsit_session " +
                "ADD KEY idx_previsit_appointment (appointment_id)",
                Array<DbValue>())
        done = done + 1
    }

    /*
     * ⑨ ★ 2026-10-14（改进 1）：`medical_record.previsit_ref`（存量库）。
     *    存的是"哪几段来自患者自述"的来源痕迹，见 DDL 处的长注释。
     *    老行补空串（= 没有来源痕迹，这是**诚实的**：那批病历确实没记过）。
     */
    let hasPvRef = db.query(
        "SELECT COUNT(*) FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'medical_record' " +
        "AND column_name = 'previsit_ref'",
        Array<DbValue>())
    if (hasPvRef.rowCount() > 0 && hasPvRef.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE medical_record " +
                "ADD COLUMN previsit_ref VARCHAR(1024) NOT NULL DEFAULT ''",
                Array<DbValue>())
        done = done + 1
    }

    return done
}
