/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * triage.cj —— 智能分诊：先取证、后结论，结论必过校验。
 * 暴露 deptRules / guessDepartment / TriageRepo / triageComplaint 及 TriageVerdict 等类型。
 * 约束：选项（科室 + 医生 + 号源）永远由规则与数据库决定，模型只贡献解释文字，改不了它。
 * 约束：只有验证到真的有号才给出选项，绝不返回没号的推荐（AC-P2-2）；结论非流式。
 */

package qingzhou

import std.collection.*

/* ===================== 来源与原因码 ===================== */

/* 来源只有 rules 与 model 两值，刻意不设 "none"：没配模型时是 rules 兜底，不是空结论。 */
public let TRIAGE_SOURCE_RULES: String = "rules"
public let TRIAGE_SOURCE_MODEL: String = "model"

/* 原因码用稳定码而非句子：改文案不会弄红测试，码变了才说明语义变了。 */
public let TR_RED_FLAG: String = "RED_FLAG"                  // 命中危急征象 → 转急诊/人工
public let TR_NO_COMPLAINT: String = "NO_COMPLAINT"          // 主诉为空/太短
public let TR_NEED_CLARIFY: String = "NEED_CLARIFY"          // 无法判定，需补充信息
public let TR_NO_SUCH_DEPT: String = "NO_SUCH_DEPT"          // 规则认出的科室在本院不存在
public let TR_NO_BOOKABLE: String = "NO_BOOKABLE"            // 认出的科室**当下没有可挂号源**
public let TR_ALTERNATIVES: String = "ALTERNATIVES"          // 首选没号，但给出了**有号的**备选
public let TR_OK: String = "OK"                              // 推荐且**已验证有号**

/* 结论类型：一个已验证可挂号的选项，一份结论；结论是业务值，字段划分见下。 */

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
 * 分诊结论（业务值）：reasonCode 稳定可断言，patientNote 是给患者的纯文本，两者分离；
 * redFlag 单独成字段，客户端不必靠解析错误码判断是否去急诊。
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
    /* 模型只贡献解释文字：options 由规则 + 数据库决定，模型改不了它，幻觉推荐绕不过验证层。 */
    public var aiNote: String = ""
    /* 为什么没用上模型（给运维看；不含密钥）。 */
    public var aiReason: String = ""
    /* 遥测五项随结论走（耗时/降级码/是否用知识库/模型 id 与名字），全是调用事实，不含患者输入；名字冗余存一份，否则模型改名会让历史聚合变义。 */
    public var aiElapsedMs: Int64 = 0
    public var aiDegradeReason: String = ""
    public var aiUsedKb: Bool = false
    public var aiModelId: Int64 = 0
    public var aiModelName: String = ""
    /* 带给模型的文档 id（逗号分隔，空 = 未用知识库）：存 id 不存正文，够定位即可。 */
    public var aiKbDocIds: String = ""
    public func hasBookable(): Bool {
        return options.size > 0
    }
}

/* 科室判定：静态规则表 + 关键词匹配，模型不能新增科室、不能改关键词语义。 */

/* 一个科室的分诊口径：本院科室名 + 主诉关键词 + 医生专长词；本表是唯一变更入口。 */
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

/* 分诊规则表（示例级，非临床指南）：越靠前越专，先匹配到的胜出，心血管内科必须排在"内科"之前。 */
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

/* 按主诉猜科室（规则实现）：第一个关键词被命中的科室胜出；命中数不作打分，否则词表大的科室占优。 */
public func guessDepartment(chiefComplaint: String): DeptGuess {
    let g = DeptGuess()
    let segs = redFlagSegments(chiefComplaint)
    for (rule in deptRules()) {
        let hits = ArrayList<String>()
        for (kw in rule.keywords) {
            for (seg in segs) {
                /* 必须走 redFlagHit（带否定判定），不能写裸 seg.contains(kw)：否则"不胸闷，只是咳嗽"会被推到心血管内科，且校验照样通过。 */
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

/* 一个可挂号的候选：字段全部来自 SQL 结果，没有一个是模型生成的。 */
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

/* 验证层：只读 schedule/doctor/department，绝不写（写只能经 BookingRepo）。 */
public class TriageRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 查某科室当前可挂号的号源：谓词守启用与真实日期，再要求 s.remain_num > 0（AC-P2-2 的根）、s.work_date >= today。
     * today 传参而不用 CURDATE()（否则同日测试依赖时区）；排序 work_date, period 升序：给最早能看的。
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

    /* 科室名在本院是否存在：区分规则表与本院科室不一致（该改规则表）与暂时没号（无需改）。 */
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

/* 结论装配：按医生归并，同一医生只留最早排班。 */

/* 把号源归并成按医生的选项：同一医生多个排班只留最早的那个，其余余额累加进 totalRemain。 */
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
 * 分诊主流程：顺序不可调换 —— 保险丝 → 主诉有效性 → 科室判定 → 验证 → 装配；验证不到有号就不给选项（AC-P2-2）。
 */
public func triageComplaint(repo: TriageRepo, chiefComplaint: String, today: String,
                            limit!: Int64 = 3, redFlagComplaint!: ?String = None): TriageVerdict {
    let v = TriageVerdict()
    v.source = TRIAGE_SOURCE_RULES

    // ① 保险丝：危急征象优先于一切；检测用完整原文，仅检索与模型输入可截断。
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
    /* 先存 deptMissing 再用：备选分支会把 reasonCode 覆盖成 TR_ALTERNATIVES，之后就分不出科室不存在了。 */
    let deptMissing = !repo.departmentExists(guess.deptName)
    if (deptMissing) {
        v.reasonCode = TR_NO_SUCH_DEPT
    } else {
        v.reasonCode = TR_NO_BOOKABLE
    }

    let alts = ArrayList<BookableSlot>()
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
         * 措辞必须区分"科室存在但暂时没号"与"本院没有这个科室"：混为一谈会让患者白跑一趟。
         * 只改文案不改 reasonCode —— 断言接受 ALTERNATIVES（给出有号的备选才是真实意图）。
         */
        if (deptMissing) {
            v.patientNote = "本院暂未开诊「${guess.deptName}」，建议咨询导诊台确认科室。" +
                            "以下这些科室当前有号，如需尽快就诊可考虑。"
        } else {
            v.patientNote = "建议就诊：${guess.deptName}（该科当前无可挂号源）。" +
                            "以下这些科室当前有号，如需尽快就诊可考虑。"
        }
        return v
    }

    // 全院都没号 —— **不给任何推荐**（宁可空手，也不给挂不上的号）
    if (v.reasonCode == TR_NO_SUCH_DEPT) {
        v.patientNote = "建议就诊的科室（${guess.deptName}）在本院暂未开诊，请咨询导诊台。"
    } else {
        v.patientNote = "该科当前没有可挂号源，请稍后再试或咨询导诊台。"
    }
    return v
}
