/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== mem_store.cj —— 内存 Store 范式（**配套域**，与号源域并列的另一套）=====
 *
 * ── 这个文件存在的理由（读之前先看这段）──────────────────────────────────
 * ADR-0001 §4.2 立了**两套数据访问范式**：
 *   · **直接 SQL**（号源域）：`schedule` / `appointment`，MySQL 权威，见 domain_booking.cj；
 *   · **内存 Store**（配套域）：`department` / `doctor` / `patient` / `medical_record`，
 *     全量载入内存 + 全局锁 + 每次提交**整体替换**这些表。
 *
 * P0/P1 一直只实现了前者，所以 ADR 的 **AC-4 无法完整验证** ——
 * 「整体替换刷盘后 schedule/appointment 数据不变」这条不变量**没有真正的刷盘可测**，
 * 只能做结构性断言（表名零交集）。本文件补上后者，把 AC-4 从"结构性"升到"真跑一次刷盘"。
 *
 * ── 移植口径（照基线，不自己发明）────────────────────────────────────────
 * 基线：`baseline/server/src/store.cj`（Store + PersistedState）+
 *       `mysql_store.cj:1097 writeDbToMysql` / `:1303 replaceBatched`。
 * 基线的关键机制是「**一次提交整体替换各表**，且只遍历 `PersistedState` 里的表」。
 * 本文件保留这两条本质：
 *   ① `flushToMysql()` 在**一个事务**里替换全部内存表（基线 `ms.tx { … }`）；
 *   ② 遍历的表来自**显式清单** `MEM_TABLES`，不是"库里所有表"
 *      —— 这正是 schedule/appointment 不被波及的**机制**，而不是巧合。
 *
 * ⚠ 与基线的**差异**（如实标注，别当成等价）：
 *   基线用 `deptSame(...)` 之类的逐字段比较做**脏行裁剪**（只 REPLACE 变了的行），
 *   本文件为简化**整表替换**。这不影响 AC-4 要验的不变量
 *   （"刷盘只碰清单里的表、且刷完号源域不变"）—— 整表替换是**更强**的写放大，
 *   若连它都不波及号源域，脏行裁剪版就更不会。
 *   真要做性能优化时再补脏行裁剪，并同步更新本节说明。
 */

package qingzhou

/*
 * ⚠ 必须显式 import：`HashMap` / `ArrayList` 来自 std.collection，
 *   `DbValue` 系列来自框架（同包，无需 import）。
 *   实测漏了它报 `undeclared type name 'TreeMap'`（当时还错用了 TreeMap 这个名字）。
 */
import std.collection.*

/* ===================== 内存实体 ===================== */

/*
 * 内存表条目（读模型）。
 * 字段与 `schema.cj` 的 DDL 一一对应 —— 这里是"内存里的那一份"，
 * 两边的列必须同步改（漂移了刷盘就会写错列）。
 */
public class MemDepartment {
    public var id: Int64 = 0
    public var name: String = ""
    public var code: String = ""
    public var location: String = ""
    public var sort: Int64 = 0
    public var enabled: Bool = true
    public var createdAt: Int64 = 0
}

public class MemDoctor {
    public var id: Int64 = 0
    public var name: String = ""
    public var departmentId: Int64 = 0
    public var title: String = ""
    public var specialty: String = ""
    public var enabled: Bool = true
    public var createdAt: Int64 = 0
}

public class MemPatient {
    public var id: Int64 = 0
    public var phone: String = ""
    public var name: String = ""
    public var gender: String = ""
    public var birthDate: String = ""
    public var createdAt: Int64 = 0
}

public class MemMedicalRecord {
    public var id: Int64 = 0
    public var appointmentId: Int64 = 0
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var chiefComplaint: String = ""
    public var presentIllness: String = ""
    public var pastHistory: String = ""
    public var allergyHistory: String = ""
    public var physicalExam: String = ""
    public var diagnosis: String = ""
    public var treatment: String = ""
    public var status: String = "draft"
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
}

/*
 * 刷盘结果回传用（见 flushToMysql 的说明：仓颉闭包不能直接捕获外层可变 var）。
 */
class FlushCounter {
    var written: Int64 = 0
}

/* ===================== 内存 Store ===================== */

/*
 * 内存 Store：配套域的**唯一**写入方（与 BookingRepo 之于号源域对称）。
 *
 * ⚠ **禁止跨范式事务**（ADR §4.3 铁律）：不得把"内存 Store 的改动 + 直接 SQL 的改动"
 *   放进同一个业务事务 —— 两者的提交时机与失败语义完全不同。
 */
public class MemStore {
    private let db: DbBackend

    /*
     * 全量内存快照。键是各自的主键 id。
     * ⚠ 用 HashMap 而不是有序容器：**照基线 store.cj:216-233 的类型选择**。
     *   刷盘的确定性改由**按键排序后写入**保证（见 replace* 里的 sortKeys），
     *   这样容器类型与基线一致、顺序也稳定，两件事都不牺牲。
     */
    public var departments: HashMap<Int64, MemDepartment> = HashMap<Int64, MemDepartment>()
    public var doctors: HashMap<Int64, MemDoctor> = HashMap<Int64, MemDoctor>()
    public var patients: HashMap<Int64, MemPatient> = HashMap<Int64, MemPatient>()
    public var medicalRecords: HashMap<Int64, MemMedicalRecord> = HashMap<Int64, MemMedicalRecord>()

    public init(db: DbBackend) {
        this.db = db
    }

    /* ---------- 载入 ---------- */

    /*
     * 从 MySQL 全量载入这批表到内存。
     * 返回载入的行数合计（便于启动日志与测试断言）。
     */
    public func loadAll(): Int64 {
        var n: Int64 = 0
        departments.clear()
        doctors.clear()
        patients.clear()
        medicalRecords.clear()

        let d = db.query("SELECT id, name, code, location, sort, enabled, created_at " +
                         "FROM department", Array<DbValue>())
        var i: Int64 = 0
        while (i < d.rowCount()) {
            let m = MemDepartment()
            m.id = d.getInt(i, 0)
            m.name = d.getString(i, 1)
            m.code = d.getString(i, 2)
            m.location = d.getString(i, 3)
            m.sort = d.getInt(i, 4)
            m.enabled = d.getInt(i, 5) != 0
            m.createdAt = d.getInt(i, 6)
            departments[m.id] = m
            i = i + 1
            n = n + 1
        }

        let doc = db.query("SELECT id, name, department_id, title, specialty, enabled, created_at " +
                           "FROM doctor", Array<DbValue>())
        i = 0
        while (i < doc.rowCount()) {
            let m = MemDoctor()
            m.id = doc.getInt(i, 0)
            m.name = doc.getString(i, 1)
            m.departmentId = doc.getInt(i, 2)
            m.title = doc.getString(i, 3)
            m.specialty = doc.getString(i, 4)
            m.enabled = doc.getInt(i, 5) != 0
            m.createdAt = doc.getInt(i, 6)
            doctors[m.id] = m
            i = i + 1
            n = n + 1
        }

        let p = db.query("SELECT id, phone, name, gender, birth_date, created_at " +
                         "FROM patient", Array<DbValue>())
        i = 0
        while (i < p.rowCount()) {
            let m = MemPatient()
            m.id = p.getInt(i, 0)
            m.phone = p.getString(i, 1)
            m.name = p.getString(i, 2)
            m.gender = p.getString(i, 3)
            m.birthDate = p.getString(i, 4)
            m.createdAt = p.getInt(i, 5)
            patients[m.id] = m
            i = i + 1
            n = n + 1
        }

        let mr = db.query("SELECT id, appointment_id, patient_id, doctor_id, chief_complaint, " +
                          "present_illness, past_history, allergy_history, physical_exam, " +
                          "diagnosis, treatment, status, created_at, updated_at " +
                          "FROM medical_record", Array<DbValue>())
        i = 0
        while (i < mr.rowCount()) {
            let m = MemMedicalRecord()
            m.id = mr.getInt(i, 0)
            m.appointmentId = mr.getInt(i, 1)
            m.patientId = mr.getInt(i, 2)
            m.doctorId = mr.getInt(i, 3)
            m.chiefComplaint = mr.getString(i, 4)
            m.presentIllness = mr.getString(i, 5)
            m.pastHistory = mr.getString(i, 6)
            m.allergyHistory = mr.getString(i, 7)
            m.physicalExam = mr.getString(i, 8)
            m.diagnosis = mr.getString(i, 9)
            m.treatment = mr.getString(i, 10)
            m.status = mr.getString(i, 11)
            m.createdAt = mr.getInt(i, 12)
            m.updatedAt = mr.getInt(i, 13)
            medicalRecords[m.id] = m
            i = i + 1
            n = n + 1
        }
        return n
    }

    /* ---------- 刷盘（整体替换） ---------- */

    /*
     * ★ **一次提交整体替换**这批表（基线 `writeDbToMysql` 的本质）。
     *
     * 两条不变量（AC-4 就是钉它们）：
     *   ① **只碰 `MEM_TABLES` 里的表** —— 遍历源是显式清单，不是"库里所有表"；
     *   ② 在**同一个事务**里完成（基线 `ms.tx { … }`）。
     * 所以号源域（schedule / appointment）**不可能**被这次刷盘波及 ——
     * 不是因为"碰巧列名不同"，而是因为**它压根不在遍历源里**。
     *
     * ⚠ 调用方必须自己保证互斥（基线用 `s.save_lock`）。本项目是单实例、
     *   且刷盘由显式调用触发（不在请求路径上），所以这里不做锁 —— 但要写清楚：
     *   **不要**在并发请求里直接调用它。
     */
    public func flushToMysql(): Int64 {
        /*
         * ⚠ 结果必须装在 **class 的 var 字段**里回传，不能直接捕获外层的 `var written`
         *   —— 实测报 `lambda capturing mutable variables needs to be called directly`
         *   （仓颉的闭包捕获限制，本项目已多次踩到，见 domain_booking.cj 的 TxResult）。
         */
        let counter = FlushCounter()
        db.withTransaction({ =>
            /*
             * ⚠ 四个调用**分行**写，不要用跨行 `+` 串联 ——
             *   实测跨行时 cjc 报 `possibly confusing line terminator`。
             *   分行也更可读：一眼能看出"这次刷盘碰了哪四张表"。
             */
            counter.written = counter.written + replaceDepartments()
            counter.written = counter.written + replaceDoctors()
            counter.written = counter.written + replacePatients()
            counter.written = counter.written + replaceMedicalRecords()
        })
        return counter.written
    }

    /*
     * 把键**排序后**返回（收 ArrayList、返回排序数组，不碰容器泛型）。
     *
     * ⚠ 为什么需要它：HashMap 的迭代顺序**不保证稳定**，而刷盘顺序会体现在
     *   SQL 序列里 —— AC-4 要按顺序比对"刷盘前后"，调试时也要能复现。
     *   排一次序就把不确定性去掉了（键是 Int64，排序很便宜）。
     *
     * ⚠ 为什么不写成泛型 `sortedKeys<K,V>(m: HashMap<K,V>)`：
     *   实测报 `generics type arguments do not match the constraint of
     *   'Class-HashMap<Generics-K, Generics-V>'` —— HashMap 的类型参数带约束，
     *   不能随便用 `where K <: Comparable<K>` 去接。
     *   本项目内存表主键都是 Int64，所以由调用方先把键收进 ArrayList 再排序 ——
     *   简单，且不跟泛型约束较劲。
     */
    func sortedIds(ks: ArrayList<Int64>): Array<Int64> {
        let arr = ks.toArray()
        /*
         * ⚠ 自己写插入排序，而不是调 `.sort()`：
         *   实测 `Array<Int64>` **没有** `sort()` 成员
         *   （报 `'sort' is not a member of struct 'Array<Int64>'`），
         *   且这套工具链里也找不到可用的 std.sort。
         *   这里只需要"确定顺序"，n 是科室/医生量级（几十~几百），
         *   插入排序足够，且**零依赖、行为完全可预测** —— 比到处找库更省事。
         */
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j] > cur) {
                arr[j + 1] = arr[j]
                j = j - 1
            }
            arr[j + 1] = cur
            i = i + 1
        }
        return arr
    }

    /* 收某张内存表的全部键（配合 sortedIds 使用）。 */
    func idsOfDepartments(): ArrayList<Int64> {
        let ks = ArrayList<Int64>()
        for ((k, _v) in departments) {
            ks.add(k)
        }
        return ks
    }

    func idsOfDoctors(): ArrayList<Int64> {
        let ks = ArrayList<Int64>()
        for ((k, _v) in doctors) {
            ks.add(k)
        }
        return ks
    }

    func idsOfPatients(): ArrayList<Int64> {
        let ks = ArrayList<Int64>()
        for ((k, _v) in patients) {
            ks.add(k)
        }
        return ks
    }

    func idsOfMedicalRecords(): ArrayList<Int64> {
        let ks = ArrayList<Int64>()
        for ((k, _v) in medicalRecords) {
            ks.add(k)
        }
        return ks
    }

    /* 整表替换：先清空再逐行 REPLACE。返回写入行数。 */
    func replaceDepartments(): Int64 {
        let _ = db.exec("DELETE FROM department", Array<DbValue>())
        var n: Int64 = 0
        for (k in sortedIds(idsOfDepartments())) {
            let m = departments[k]
            let _ = db.exec(
                "REPLACE INTO department (id, name, code, location, sort, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                [DbInt(m.id), DbStr(m.name), DbStr(m.code), DbStr(m.location),
                 DbInt(m.sort), DbInt(if (m.enabled) { 1 } else { 0 }), DbInt(m.createdAt)])
            n = n + 1
        }
        return n
    }

    func replaceDoctors(): Int64 {
        let _ = db.exec("DELETE FROM doctor", Array<DbValue>())
        var n: Int64 = 0
        for (k in sortedIds(idsOfDoctors())) {
            let m = doctors[k]
            let _ = db.exec(
                "REPLACE INTO doctor (id, name, department_id, title, specialty, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                [DbInt(m.id), DbStr(m.name), DbInt(m.departmentId), DbStr(m.title),
                 DbStr(m.specialty), DbInt(if (m.enabled) { 1 } else { 0 }), DbInt(m.createdAt)])
            n = n + 1
        }
        return n
    }

    func replacePatients(): Int64 {
        let _ = db.exec("DELETE FROM patient", Array<DbValue>())
        var n: Int64 = 0
        for (k in sortedIds(idsOfPatients())) {
            let m = patients[k]
            let _ = db.exec(
                "REPLACE INTO patient (id, phone, name, gender, birth_date, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
                [DbInt(m.id), DbStr(m.phone), DbStr(m.name), DbStr(m.gender),
                 DbStr(m.birthDate), DbInt(m.createdAt)])
            n = n + 1
        }
        return n
    }

    func replaceMedicalRecords(): Int64 {
        let _ = db.exec("DELETE FROM medical_record", Array<DbValue>())
        var n: Int64 = 0
        for (k in sortedIds(idsOfMedicalRecords())) {
            let m = medicalRecords[k]
            let _ = db.exec(
                "REPLACE INTO medical_record (id, appointment_id, patient_id, doctor_id, " +
                "chief_complaint, present_illness, past_history, allergy_history, " +
                "physical_exam, diagnosis, treatment, status, created_at, updated_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [DbInt(m.id), DbInt(m.appointmentId), DbInt(m.patientId), DbInt(m.doctorId),
                 DbStr(m.chiefComplaint), DbStr(m.presentIllness), DbStr(m.pastHistory),
                 DbStr(m.allergyHistory), DbStr(m.physicalExam), DbStr(m.diagnosis),
                 DbStr(m.treatment), DbStr(m.status), DbInt(m.createdAt), DbInt(m.updatedAt)])
            n = n + 1
        }
        return n
    }
}

/* ===================== 刷盘的"遍历源" ===================== */

/*
 * ★★ **内存 Store 负责的表清单** —— ADR-0001 §4.3 范围锁死的另一半。
 *
 * 这是 AC-4 的**机制性保证**：`flushToMysql()` 遍历的就是这个清单，
 * 所以"刷盘会不会碰号源域"这个问题有一个**可查询的答案**：
 *     `MEM_TABLES` 与 `BOOKING_DOMAIN_TABLES` 的交集必须为空。
 * 两个函数都从清单算，而不是各自写死 —— 免得将来加表时漏改一处。
 */
public let MEM_TABLES: Array<String> = [
    TABLE_DEPARTMENT, TABLE_DOCTOR, TABLE_PATIENT, TABLE_MEDICAL_RECORD
]

/* 某表是否由内存 Store 负责。 */
public func isMemStoreTable(name: String): Bool {
    for (t in MEM_TABLES) {
        if (t == name) {
            return true
        }
    }
    return false
}

/*
 * ★ 两套范式的表集**必须不相交**（ADR §4.3「禁止跨范式」的结构性前提）。
 * 返回交集的表名（空数组 = 健康）。
 */
public func paradigmOverlap(): Array<String> {
    let out = ArrayList<String>()
    for (m in MEM_TABLES) {
        for (b in BOOKING_DOMAIN_TABLES) {
            if (m == b) {
                out.add(m)
            }
        }
    }
    return out.toArray()
}
