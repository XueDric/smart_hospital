/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== triage.cj —— 智能分诊：先取证、后结论，结论必过校验 ================
 *
 * ── 本文件的核心纪律（照搬迁前的 `ai_client.cj` 设计口径 2）──────────────
 *   「**绝不把没校验过的内容当业务值返回**」
 *
 * 分诊结论是**业务值**（要拿它去挂号），所以它必须：
 *   ① **非流式**（brief §5.2）：分诊结论不能边生成边推给客户端 ——
 *      那样客户端会先拿到"推荐心内科"再拿到"其实推荐呼吸科"，
 *      而它可能已经拿第一句去挂 号了。**结论只有一个，且必须校验后才存在。**
 *   ② **经过验证**：推荐的科室/医生**必须真的有号**（AC-P2-2）。
 *      否则患者拿着推荐去挂号，发现没号 —— 那比不推荐更坏。
 *
 * ── 分层（每层都能单独测，这是本项目一贯做法）────────────────────────────
 *   `triage_redflag.cj`  纯规则保险丝，不碰库不调模型（已独立成文件）
 *   本文件：
 *     · 科室判定（规则实现；接口留好给将来接模型）
 *     · **验证**（唯一会碰 `schedule` 的地方）—— 绝不给没号的推荐
 *     · 结论装配（三态来源 + 稳定 reason 码）
 *
 * ⚠⚠ **本轮不接真模型** —— Q6（AI 模型选型与合规）仍是**待决问题**
 *   （brief §10：患者主诉属敏感信息，出境/第三方处理需评估）。
 *   所以本文件把"科室判定"抽成**可替换的接口**，默认用**关键词规则**实现，
 *   并在结论里用 `source` 如实标注是规则还是模型。
 *   这样做的价值：**所有与模型无关的纪律（保险丝、校验、三态、可观测）
 *   都能落地并有测试**；将来接上模型时只换一个实现，其余不动。
 *   📌 不假装"AI 已完成"：`TRIAGE_SOURCE_RULES` 就是规则，不是 AI。
 */

package qingzhou

import std.collection.*

/* ===================== 来源与原因码 ===================== */

/*
 * 三态来源（照搬迁前的 `ai_client.cj` 的 `AI_SOURCE_*`）。
 * ⚠ 这里**只会有两个值**：`rules`（本轮唯一的真实实现）与将来可能出现的 `model`。
 *   刻意不设 `"none"` —— 照搬迁前 R-8 的口径：规则兜底**不得为空**，
 *   所以"AI 没配置"时的正确表现是 `rules` + 有内容的结论，而不是"什么都没有"。
 */
public let TRIAGE_SOURCE_RULES: String = "rules"
public let TRIAGE_SOURCE_MODEL: String = "model"

/*
 * 稳定的原因码（进审计与测试断言用）。
 * ⚠ 用**码**而不是句子：句子会被改（改文案 → 测试假红），码不会。
 *   患者可见的说明另有一份文案（见 `TriageVerdict.patientNote`）。
 */
public let TR_RED_FLAG: String = "RED_FLAG"                  // 命中危急征象 → 转急诊/人工
public let TR_NO_COMPLAINT: String = "NO_COMPLAINT"          // 主诉为空/太短
public let TR_NEED_CLARIFY: String = "NEED_CLARIFY"          // 无法判定，需补充信息
public let TR_NO_SUCH_DEPT: String = "NO_SUCH_DEPT"          // 规则认出的科室在本院不存在
public let TR_NO_BOOKABLE: String = "NO_BOOKABLE"            // 认出的科室**当下没有可挂号源**
public let TR_ALTERNATIVES: String = "ALTERNATIVES"          // 首选没号，但给出了**有号的**备选
public let TR_OK: String = "OK"                              // 推荐且**已验证有号**

/* ===================== 结论类型 ===================== */

/* 一个"已验证可挂号"的选项：科室 + 医生 + 号源事实。 */
public class TriageOption {
    public var departmentId: Int64 = 0
    public var departmentName: String = ""
    public var doctorId: Int64 = 0
    public var doctorName: String = ""
    public var doctorTitle: String = ""
    /* 最早的可用排班（这就是"真的有号"的证据）。 */
    public var scheduleId: Int64 = 0
    public var workDate: String = ""
    public var period: String = ""
    public var remainNum: Int64 = 0
    /* 该科室在查询窗口内**合计**可挂号源（给患者"号源是否紧张"的直觉）。 */
    public var totalRemain: Int64 = 0
}

/*
 * ★ 分诊结论（**业务值**，因此必须非流式且校验后才存在）。
 *
 * 字段设计的两条理由：
 *   · `reasonCode` 稳定可断言；`patientNote` 是给患者看的话 —— 两者分离，
 *     这样改文案不会弄红测试，而改**语义**会（因为码变了）。
 *   · `redFlag` 单独成字段而不是塞进 reasonCode：客户端**必须**能一眼判断
 *     "这是不是要去急诊"，不该靠解析错误码来推断。
 */
public class TriageVerdict {
    /* OK / ALTERNATIVES 时非空 —— 且**一定**是已验证有号的。 */
    public var options: Array<TriageOption> = Array<TriageOption>()
    public var redFlag: Bool = false
    public var reasonCode: String = ""
    public var source: String = TRIAGE_SOURCE_RULES
    /* 危急依据（只在 redFlag 时非空；进审计，不直接给患者看）。 */
    public var redFlagEvidence: String = ""
    /* 给患者看的一句话（可为空）。 */
    public var patientNote: String = ""
    /*
     * ★ 2026-10-09 接真模型：模型给的**解释文字**。
     *
     * ⚠⚠ 它与 `options` 是**两回事**，这个划分是刻意且不可让步的：
     *   `options`（科室 + 排班 + 号源）**永远由规则 + 数据库决定**，
     *   模型**一个字节都改不了它** —— 于是 P2 立的"**绝不给没有号的推荐**"
     *   这条硬性验证层**不可能被模型绕过**（模型幻觉推荐一个没号的科室，
     *   是比规则出错更难发现的失败形态：它看起来很有道理）。
     *   ⇒ 模型只让"给患者的说明"更好读，不让"能不能挂号"发生变化。
     */
    public var aiNote: String = ""
    /* 为什么没用上模型（给运维看；不含密钥）。 */
    public var aiReason: String = ""
    /* 是否**真的**给出了可挂号的推荐。 */
    public func hasBookable(): Bool {
        return options.size > 0
    }
}

/* ===================== 科室判定 ===================== */

/*
 * 一个科室的分诊口径：本院科室名 + 主诉关键词 + 医生专长词。
 *
 * ⚠ 这是**静态表**（照搬迁前的 `aiToolSpecs` 的"静态白名单"纪律）：
 *   模型**不能新增科室**，也不能改关键词语义。
 *   将来 P3「AI 能力中心」会把它改成 DB 驱动（brief §5.3），那时
 *   本表变成"出厂默认值"，而**变更入口仍只有一处**。
 */
public class DeptRule {
    public let deptName: String
    public let keywords: Array<String>
    public let doctorSpecialties: Array<String>

    public init(deptName: String, keywords: Array<String>, doctorSpecialties: Array<String>) {
        this.deptName = deptName
        this.keywords = keywords
        this.doctorSpecialties = doctorSpecialties
    }
}

/*
 * 分诊规则表（示例级，覆盖本院常见主诉）。
 *
 * ⚠ 三条如实标注：
 *   · **不是临床指南**，是把"最常见的主诉 → 科室"写成可测的映射；
 *   · 词表**示例级**（与弱口令表/红牌词表同一处置口径），要更全需临床输入；
 *   · 顺序有意义：**靠前的先匹配**（同一主诉命中多科时取更专的那个），
 *     所以"心血管内科"要排在"内科"之前 —— 这是刻意排序，不是随手排。
 */
public func deptRules(): Array<DeptRule> {
    return [
        DeptRule("心血管内科",
                 ["胸闷", "心悸", "心慌", "血压", "高血压", "冠心病", "心律", "心绞痛", "心脏"],
                 ["心血管", "高血压", "冠心病", "心律"]),
        DeptRule("神经内科",
                 ["头晕", "头痛", "偏头痛", "失眠", "麻木", "手麻", "脚麻", "眩晕", "面瘫", "癫痫"],
                 ["神经", "脑血管", "头痛", "眩晕"]),
        DeptRule("呼吸内科",
                 ["咳嗽", "咳痰", "气短", "哮喘", "肺炎", "支气管", "呼吸", "咽痛", "打鼾"],
                 ["呼吸", "哮喘", "慢阻肺", "肺"]),
        DeptRule("消化内科",
                 ["胃痛", "腹痛", "反酸", "烧心", "腹泻", "拉肚子", "便秘", "恶心", "呕吐",
                  "腹胀", "消化不良", "胃"],
                 ["消化", "胃肠", "肝", "胃"]),
        DeptRule("内分泌科",
                 ["血糖", "糖尿病", "甲亢", "甲状腺", "肥胖", "多饮", "多尿", "痛风", "血脂"],
                 ["内分泌", "糖尿病", "甲状腺"]),
        DeptRule("骨科",
                 ["腰痛", "颈椎", "关节", "骨折", "扭伤", "腰腿痛", "肩膀疼", "膝盖", "骨"],
                 ["骨科", "关节", "脊柱", "创伤"]),
        DeptRule("皮肤科",
                 ["皮疹", "瘙痒", "痒", "湿疹", "荨麻疹", "痤疮", "痘痘", "脱发", "皮肤", "斑"],
                 ["皮肤", "湿疹", "荨麻疹"]),
        DeptRule("眼科",
                 ["视力", "眼睛", "眼痛", "流泪", "红眼", "看不清", "近视", "白内障"],
                 ["眼科", "眼底", "白内障"]),
        DeptRule("耳鼻喉科",
                 ["耳鸣", "耳痛", "鼻塞", "流鼻血", "鼻炎", "扁桃体", "声音嘶哑", "喉咙"],
                 ["耳鼻喉", "鼻", "咽喉"]),
        DeptRule("儿科",
                 ["孩子", "小孩", "宝宝", "婴儿", "儿童", "幼儿", "娃", "宝宝发烧"],
                 ["儿科", "新生儿", "儿童"]),
        DeptRule("妇产科",
                 ["月经", "痛经", "白带", "怀孕", "孕期", "产后", "妇科", "乳腺", "备孕"],
                 ["妇科", "产科", "乳腺"]),
        DeptRule("泌尿外科",
                 ["尿频", "尿急", "尿痛", "血尿", "前列腺", "结石", "肾"],
                 ["泌尿", "结石", "前列腺"]),
        DeptRule("口腔科",
                 ["牙痛", "牙疼", "牙龈", "口腔溃疡", "拔牙", "蛀牙", "智齿"],
                 ["口腔", "牙"]),
        // ⚠ "内科"放最后：它最泛，命中它说明没有更专的科室匹配上
        DeptRule("内科",
                 ["发烧", "发热", "感冒", "乏力", "全身", "没力气", "不舒服", "体检"],
                 ["内科", "全科"])
    ]
}

/* 规则命中结果：科室名 + 命中的关键词（留下依据，便于审计与解释）。 */
public class DeptGuess {
    public var deptName: String = ""
    public var matched: Array<String> = Array<String>()

    public func found(): Bool {
        return deptName.size > 0
    }
}

/*
 * ★ 按主诉猜科室（**规则实现**）。
 *
 * 判定：遍历 `deptRules()`，第一个"任一关键词被命中"的科室胜出。
 * ⚠ **命中数不作为打分依据** —— 用"命中几个词"打分会让长主诉天然偏向
 *   词表大的科室（"内科"词表有 8 个词，很容易压过只有 2 个词的专科）。
 *   "**先匹配到的更专**"这条顺序纪律，比一个拍脑袋的分数更可解释。
 */
public func guessDepartment(chiefComplaint: String): DeptGuess {
    let g = DeptGuess()
    let segs = redFlagSegments(chiefComplaint)
    for (rule in deptRules()) {
        let hits = ArrayList<String>()
        for (kw in rule.keywords) {
            for (seg in segs) {
                /*
                 * ★★ 必须走 `redFlagHit`（**带否定判定**），不能写裸 `seg.contains(kw)`。
                 *
                 * ── 原缺陷（第五份复查抓出，我已实测复现）─────────────────────────
                 * 红色保险丝那条路处理了否定，但**科室判定这条路用的是裸 contains**，
                 * 于是患者**明确否认**的症状会主导推荐。实测（让心血管内科有号后）：
                 *     '不胸闷，只是咳嗽'   -> 推荐【心血管内科】   ✗
                 *     '没有胸闷，就是咳嗽' -> 推荐【心血管内科】   ✗
                 *     '否认胸闷，主要咳嗽' -> 推荐【心血管内科】   ✗
                 *     '咳嗽'（对照）       -> 推荐【呼吸内科】     ✓
                 *
                 * 危害比"分错科"更隐蔽：因为**有号校验是通过的**，响应 `reason=OK`、
                 * 还附了真实医生与号源 ⇒ **看起来非常权威**，患者很可能照着去挂错科。
                 *
                 * ── 为什么是"复用"而不是"再写一套否定判断"────────────────────────
                 * 两条路（保险丝 / 科室判定）需要的是**同一个语义**："这个词有没有被否定"。
                 * 写成两处实现，就是又一次"同一件事两处口径" —— 本项目已为此吃过多次
                 * （登录名归一、连接参数、文档数字）。所以这里**直接复用同一套函数**：
                 * 同一个分句（redFlagSegments）+ 同一个字符空间否定窗口（redFlagHit）。
                 *
                 * `negated` 传 `None`：科室判定**不需要**留"被否定的依据"档
                 *   （那是保险丝给审计用的），传 None 让这个意图显式化。
                 */
                if (redFlagHit(seg, kw, hits, None)) {
                    // 命中即记（redFlagHit 已保证去重）
                }
            }
        }
        if (hits.size > 0) {
            g.deptName = rule.deptName
            g.matched = hits.toArray()
            return g
        }
    }
    return g
}

/* ===================== 验证（唯一碰 schedule 的地方）===================== */

/*
 * 一个"可挂号"的候选（库里查出来的事实，不含任何推测）。
 * 字段全部来自 SQL 结果，没有一个是模型生成的。
 */
public class BookableSlot {
    public var scheduleId: Int64 = 0
    public var departmentId: Int64 = 0
    public var departmentName: String = ""
    public var doctorId: Int64 = 0
    public var doctorName: String = ""
    public var doctorTitle: String = ""
    public var doctorSpecialty: String = ""
    public var workDate: String = ""
    public var period: String = ""
    public var remainNum: Int64 = 0
}

/*
 * ★★ 分诊的**验证层** —— 只读 `schedule` / `doctor` / `department`，绝不写。
 *
 * ADR-0001 §4.3「范围锁死」要求：直接 SQL 只准落在 `BookingRepo` 拥有的表上。
 * `schedule` 正是其中之一，所以本类**必须**只在读语义下使用它，
 * 且**不得**在这里做任何写操作（写只能经 `BookingRepo`）。
 * 这是刻意把"读"与"写"分开：分诊永远不该改变号源状态。
 */
public class TriageRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 查某科室**当前可挂号**的号源（按就诊日/时段升序）。
     *
     * 过滤条件：共同可售谓词守住排班/科室/医生启用、归属与真实日期时段，
     *   再要求余额与调用方的医院日期：
     *   · `s.remain_num > 0` —— **真的有余额**（这就是 AC-P2-2 的根）
     *   · `s.work_date >= today` —— 别把过期排班推给患者
     *
     * ⚠ `today` 由**调用方**传入而不是在 SQL 里 `CURDATE()`：
     *   后者会让"同一天的测试"依赖数据库时区，测起来会偶发红。
     *   传参后测试可以固定日期，行为完全可复现。
     *
     * 排序：`work_date ASC, period ASC` —— 给患者"最早能看的"，
     *   而不是"号最多的"（患者要的是尽快看上病）。
     */
    public func bookableSlotsInDepartment(deptName: String, today: String,
                                          limit!: Int64 = 20): Array<BookableSlot> {
        let cap = if (limit <= 0) { 20 } else if (limit > 100) { 100 } else { limit }
        let rs = db.query(
            "SELECT s.id, s.department_id, d.name, s.doctor_id, dr.name, dr.title, dr.specialty, " +
            "s.work_date, s.period, s.remain_num " +
            "FROM schedule s " +
            "JOIN department d ON d.id = s.department_id " +
            "JOIN doctor dr ON dr.id = s.doctor_id " +
            "WHERE d.name = ? AND s.remain_num > 0 AND " + bookingSchedulePredicate("s") + " " +
            "ORDER BY s.work_date ASC, s.period ASC, s.id ASC LIMIT ?",
            [DbStr(deptName), DbStr(today), DbInt(cap)])
        let out = ArrayList<BookableSlot>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let b = BookableSlot()
            b.scheduleId = rs.getInt(i, 0)
            b.departmentId = rs.getInt(i, 1)
            b.departmentName = rs.getString(i, 2)
            b.doctorId = rs.getInt(i, 3)
            b.doctorName = rs.getString(i, 4)
            b.doctorTitle = rs.getString(i, 5)
            b.doctorSpecialty = rs.getString(i, 6)
            b.workDate = rs.getString(i, 7)
            b.period = rs.getString(i, 8)
            b.remainNum = rs.getInt(i, 9)
            out.add(b)
            i = i + 1
        }
        return out.toArray()
    }

    /*
     * 某科室名在本院**是否存在**（用于区分两种失败：
     * "规则认出的科室本院没有" vs "科室有但当前没号"）。
     *
     * ⚠ 这个区分对患者没有意义（两种都只能换科室），但对**运维**有意义：
     *   前者说明**规则表与本院子集不一致**（该改规则表），
     *   后者只是"暂时没号"（什么都不用改）。混在一起会让规则表长期漂移而无人发现。
     */
    public func departmentExists(deptName: String): Bool {
        let rs = db.query("SELECT COUNT(*) FROM department WHERE name = ?", [DbStr(deptName)])
        if (rs.rowCount() < 1) {
            return false
        }
        return rs.getInt(0, 0) > 0
    }

    /* 本院**全部**科室名（按 id 升序）—— 用于"没号时给有号的备选"。 */
    public func allDepartmentNames(): Array<String> {
        let rs = db.query("SELECT name FROM department ORDER BY id ASC", Array<DbValue>())
        let out = ArrayList<String>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(rs.getString(i, 0))
            i = i + 1
        }
        return out.toArray()
    }
}

/* ===================== 结论装配 ===================== */

/*
 * 把一组 `BookableSlot` 归并成"按医生"的选项（同一医生多个排班只留最早的）。
 *
 * ⚠ 为什么按**医生**归并而不是按排班：患者要选的是"看哪个医生"，
 *   一次给他 5 个同一医生的不同日期只是噪音。首个（最早）的那个作为推荐排班，
 *   其余数量汇总进 `totalRemain`。
 */
func toOptions(slots: Array<BookableSlot>): Array<TriageOption> {
    let byDoctor = ArrayList<TriageOption>()
    for (s in slots) {
        var found: ?TriageOption = None
        for (o in byDoctor) {
            if (o.doctorId == s.doctorId) {
                found = Some(o)
                break
            }
        }
        if (found.isSome()) {
            // 已有该医生 → 只累加号源数（首个保留的是**最早**的排班）
            let o = found.getOrThrow()
            o.totalRemain = o.totalRemain + s.remainNum
        } else {
            let o = TriageOption()
            o.departmentId = s.departmentId
            o.departmentName = s.departmentName
            o.doctorId = s.doctorId
            o.doctorName = s.doctorName
            o.doctorTitle = s.doctorTitle
            o.scheduleId = s.scheduleId
            o.workDate = s.workDate
            o.period = s.period
            o.remainNum = s.remainNum
            o.totalRemain = s.remainNum
            byDoctor.add(o)
        }
    }
    return byDoctor.toArray()
}

/*
 * ★★ 分诊主流程 —— **先取证、后结论，结论必过校验**。
 *
 * 执行顺序（顺序本身就是纪律，不能调换）：
 *   ① **危急征象兜底**（纯规则，不碰库不调模型）：命中 ⇒ 立即返回 RED_FLAG，
 *      后面所有步骤**都不执行** —— 危急时不做分诊，直接转急诊/人工。
 *   ② 主诉有效性：为空/太短 ⇒ NO_COMPLAINT（不猜）。
 *   ③ 科室判定（规则/将来的模型）⇒ 得到科室名。
 *   ④ **验证**：
 *        · 科室不存在 → NO_SUCH_DEPT
 *        · 有科室但**无号** → 在其它科室里找有号的 → 有则 ALTERNATIVES，无则 NO_BOOKABLE
 *        · 有号 → OK
 *   ⑤ 只有 ③④ 都给出**已验证有号**的选项，`options` 才非空。
 *      ⇒ **任何情况下都不会返回"没号的推荐"**（AC-P2-2）。
 *
 * `today` 传参（YYYY-MM-DD）：让"过期排班不算可用"这条可被确定性测试。
 */
public func triageComplaint(repo: TriageRepo, chiefComplaint: String, today: String,
                            limit!: Int64 = 3, redFlagComplaint!: ?String = None): TriageVerdict {
    let v = TriageVerdict()
    v.source = TRIAGE_SOURCE_RULES

    // ① 保险丝：危急征象**优先于一切**
    // 危急检测使用完整、有请求体上限保护的原文；仅常规检索/模型输入允许截断。
    let rf = detectRedFlag(match (redFlagComplaint) {
        case Some(full) => full
        case None => chiefComplaint
    })
    if (rf.redFlag) {
        v.redFlag = true
        v.reasonCode = TR_RED_FLAG
        v.redFlagEvidence = rf.evidence()
        v.patientNote = "您描述的情况可能属于急症，请立即前往急诊科或拨打 120，" +
                        "不要等待门诊挂号。"
        return v
    }

    // ② 主诉太短不猜
    let text = chiefComplaint.trimAscii()
    if (text.size < 2) {
        v.reasonCode = TR_NO_COMPLAINT
        v.patientNote = "请再描述一下主要不适（例如：咳嗽三天、胃痛、头晕）。"
        return v
    }

    // ③ 科室判定
    let guess = guessDepartment(text)
    if (!guess.found()) {
        v.reasonCode = TR_NEED_CLARIFY
        v.patientNote = "暂时无法判断该看哪个科，请补充：主要不适是什么、持续了多久、" +
                        "有没有伴随症状（如发热、呕吐）。"
        return v
    }

    // ④ 验证：先看认出的科室
    let slots = repo.bookableSlotsInDepartment(guess.deptName, today, limit: limit * 6)
    if (slots.size > 0) {
        v.options = toOptions(slots)
        v.reasonCode = TR_OK
        v.patientNote = "根据您的描述，建议就诊：${guess.deptName}。"
        return v
    }

    // 该科室没号（或本院没有这个科室）→ 如实区分，并尽力给出**有号的**备选
    if (!repo.departmentExists(guess.deptName)) {
        v.reasonCode = TR_NO_SUCH_DEPT
    } else {
        v.reasonCode = TR_NO_BOOKABLE
    }

    let alts = ArrayList<BookableSlot>()
    // ⚠ 仓颉的 for 必须带括号：`for (x in ...)` —— 实测漏了报 `expected '(', found 'name'`
    for (name in repo.allDepartmentNames()) {
        if (name == guess.deptName) {
            continue
        }
        // 每个备选科室只取最早几个，避免备选列表比首选还长
        let s = repo.bookableSlotsInDepartment(name, today, limit: 2)
        for (x in s) {
            alts.add(x)
        }
        if (alts.size >= limit) {
            break
        }
    }
    if (alts.size > 0) {
        v.options = toOptions(alts.toArray())
        v.reasonCode = TR_ALTERNATIVES
        /*
         * ★ 2026-10-12：去掉 `**`（原为 Markdown 粗体标记）。
         *
         * 实测：患者端把这句**原样**显示成
         *   「以下是**其它有号**的科室，如需尽快就诊可考虑。」
         * —— 两个星号直接怼在字上，看着像出错或漏转义。
         * 根因：`patientNote` 是**给人看的纯文本**（客户端不做 Markdown 渲染，
         * 它只 `Text()` 直出），而这里按"Markdown 源文"写。
         *   ⇒ 契约是"纯文本"，那强调就**不该用标记**表达：
         *     纯文本里的强调靠**用词与语序**（本句改成"以下这些科室当前有号"
         *     已经足够清楚），而不是靠符号。
         * 📌 一般规律：**输出格式由消费方决定**。
         *    本字段的消费方是原生 UI 文本控件，不是 Markdown 渲染器。
         */
        v.patientNote = "建议就诊：${guess.deptName}（该科当前无可挂号源）。" +
                        "以下这些科室当前有号，如需尽快就诊可考虑。"
        return v
    }

    // 全院都没号 —— **不给任何推荐**（宁可空手，也不给挂不上的号）
    /*
     * ⚠ `let x = if (…) {…} else {…}` **不是**仓颉的合法写法（实测报
     *   `expected pattern, found ')'` —— if 是语句不是表达式）。改成先赋值再返回。
     */
    if (v.reasonCode == TR_NO_SUCH_DEPT) {
        v.patientNote = "建议就诊的科室（${guess.deptName}）在本院暂未开诊，请咨询导诊台。"
    } else {
        v.patientNote = "该科当前没有可挂号源，请稍后再试或咨询导诊台。"
    }
    return v
}
