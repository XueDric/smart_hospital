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
 *     **不进内存 Store**，由 MySQL 权威；扣减用 version 乐观锁 + remain_num > 0；
 *   - 其余表（department / doctor / patient / medical_record / booking_idem）为配套最小集，
 *     本阶段只建表，业务路径在 P1+ 落地。
 *
 * 基线依据（只读，见 baseline/）：
 *   - SCHEMA_DDL 写法照 baseline/server/src/mysql_store.cj:313
 *   - 参数化 exec(sql, Array<DbValue>) 见 baseline/server/third_party/qingzhou/src/db.cj:128
 *   - bindSql 会把 ? 按序替换为类型感知安全字面量（db.cj:113-131），
 *     所以 DDL 走无参 exec，数据操作走带 ? 的 exec
 *
 * ⚠ 字符集：全表 utf8mb4。基线踩过"驱动握手写死 utf8mb3 → 一个 emoji 让之后
 *   所有写入持续 500"的坑（baseline/docs/mysql-backend.md §12.10），
 *   建连后必须 SET NAMES utf8mb4（见 db_bootstrap.cj）。
 */

package qingzhou

/* ===================== 表名常量 ===================== */

/*
 * 表名集中在此，避免各处字符串拼写漂移。
 *
 * ★ 两条域划分（ADR-0001 §4.2 修订）：
 *   `BOOKING_DOMAIN_TABLES` = 号源/挂号**业务状态**表，走直接 SQL（仅此两张）；
 *   `BOOKING_INFRA_TABLES`  = 号源域的**幂等基础设施**表，不是业务状态，
 *                             但同样只能由 BookingRepo 写（不散落）。
 *
 * ⚠ 为什么叫 `booking_idem` 而不是 `idem`（P1 口径隐患，已修）：
 *   基线内存 Store 自己也有一张 `idem` 表（`baseline/server/src/mysql_store.cj:892`
 *   的 `PersistedState.idem`，DDL 同名，见该文件 §309-311「表名与 store.cj 的逻辑表名
 *   一一同名」）。两张表**语义与列定义都不同**：
 *     · 基线：`IdemRecord`（社团业务幂等）
 *     · 本侧：`idem_key` + `created_at`（挂号幂等）
 *   P1 引入内存 Store 后，整库刷盘的 `replaceBatched("idem", …)` 会与本侧的挂号幂等
 *   记录**争同一张表**。改名后两侧彻底隔离。
 */
public let TABLE_DEPARTMENT: String = "department"
public let TABLE_DOCTOR: String = "doctor"
public let TABLE_SCHEDULE: String = "schedule"
public let TABLE_APPOINTMENT: String = "appointment"
public let TABLE_PATIENT: String = "patient"
public let TABLE_MEDICAL_RECORD: String = "medical_record"
public let TABLE_BOOKING_IDEM: String = "booking_idem"

/*
 * 鉴权表（P1 令牌体系）。
 *
 * ⚠ 命名同样避开基线：基线内存 Store 占用了 `tokens`（`mysql_store.cj:891`
 *   的 `PersistedState.tokens`，DDL 同名）。所以本侧叫 **`auth_token`**。
 *   账号表叫 `auth_user`（基线没有同名表，但加 auth_ 前缀是为了让"这是鉴权域"
 *   一眼可辨，与业务表 `patient`/`doctor` 区分开）。
 */
public let TABLE_AUTH_USER: String = "auth_user"
public let TABLE_AUTH_TOKEN: String = "auth_token"

/* 号源/挂号**业务状态**表 —— 唯二走直接 SQL 的业务表（ADR-0001 §4.3）。 */
public let BOOKING_DOMAIN_TABLES: Array<String> = [TABLE_SCHEDULE, TABLE_APPOINTMENT]

/*
 * 号源域**幂等基础设施**表 —— 不是业务状态，但写它也只能经由 BookingRepo。
 * 与业务状态表分开列，是为了让「业务状态」与「基础设施」的口径不含糊（见 ADR §4.3）。
 */
public let BOOKING_INFRA_TABLES: Array<String> = [TABLE_BOOKING_IDEM]

/*
 * 全部业务表。
 * ⚠ 与 `BOOKING_DOMAIN_TABLES ∪ BOOKING_INFRA_TABLES` 的差集就是"走内存 Store 范式"的表。
 */
public let ALL_TABLES: Array<String> = [
    TABLE_DEPARTMENT, TABLE_DOCTOR, TABLE_SCHEDULE,
    TABLE_APPOINTMENT, TABLE_PATIENT, TABLE_MEDICAL_RECORD, TABLE_BOOKING_IDEM,
    TABLE_AUTH_USER, TABLE_AUTH_TOKEN
]

/* ===================== DDL ===================== */

/*
 * 建表 DDL（幂等：全部 IF NOT EXISTS）。
 *
 * 设计要点：
 *  1. `schedule.version` —— 乐观锁版本号（ADR-0001 §2.2）。每次成功扣减 +1。
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
    "UNIQUE KEY uk_department_code (code)" +
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
    // version + remain_num 是防超卖的两个支柱（ADR-0001 §2.2）。
    "CREATE TABLE IF NOT EXISTS schedule (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "doctor_id BIGINT NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "work_date VARCHAR(16) NOT NULL, " +          // 就诊日 YYYY-MM-DD（可被顺延）
    "period VARCHAR(16) NOT NULL DEFAULT 'AM', " + // AM / PM
    "total_num BIGINT NOT NULL DEFAULT 0, " +
    "remain_num BIGINT NOT NULL DEFAULT 0, " +
    "version BIGINT NOT NULL DEFAULT 0, " +        // ← 乐观锁
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
    "client_token VARCHAR(64) NOT NULL DEFAULT '', " + // ← 幂等键
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "cancelled_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    // 幂等由数据库兜底：同一 client_token 不可能落两行（AC-3）
    "UNIQUE KEY uk_appointment_client_token (client_token), " +
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
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_record_appointment (appointment_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    // ── 幂等记录（**挂号专用**，故加 booking_ 前缀）─────────────────────────
    // ⚠ 刻意**不叫** `idem`：基线内存 Store 已占用该表名（mysql_store.cj:892），
    //   且列定义不同（基线是 IdemRecord）。P1 引入内存 Store 后整库刷盘
    //   `replaceBatched("idem", …)` 会与本表争同一张表。见文件头说明。
    "CREATE TABLE IF NOT EXISTS booking_idem (" +
    "idem_key VARCHAR(160) NOT NULL, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (idem_key), " +
    "KEY idx_booking_idem_created (created_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

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
    // ⚠ 刻意**不叫** `tokens`：基线内存 Store 已占用该表名（mysql_store.cj:891）。
    // 令牌是 64 个十六进制字符（32 字节随机），用 VARCHAR(64) 主键。
    // 服务端存 token → user 映射 ⇒ **不是无状态 JWT**，所以"停用账号"能立即踢下线。
    "CREATE TABLE IF NOT EXISTS auth_token (" +
    "token VARCHAR(64) NOT NULL, " +
    "user_id BIGINT NOT NULL, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "expires_at BIGINT NOT NULL DEFAULT 0, " +
    "last_renew_at BIGINT NOT NULL DEFAULT 0, " +  // 滑动续期节流用
    "PRIMARY KEY (token), " +
    "KEY idx_auth_token_user (user_id), " +
    "KEY idx_auth_token_expires (expires_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* ===================== 建表入口 ===================== */

/*
 * 幂等建表：逐条执行 SCHEMA_DDL。
 *
 * 为什么不用框架 `ensureTable(name, columns)`：它的入参是**列定义片段**，
 * 表达不了唯一索引、复合索引与 ENGINE/CHARSET；而幂等（AC-3）恰恰依赖唯一索引。
 * 所以这里直接用完整 DDL 文本，与基线 mysql_store.cj:384 同一写法。
 *
 * 返回：实际执行的语句数（便于启动日志与测试断言）。
 */
public func ensureSchema(db: DbBackend): Int64 {
    var n: Int64 = 0
    for (sql in SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    return n
}

/*
 * 判定某表是否属于「号源/挂号的**业务状态**」，即走直接 SQL 的那两张。
 * 用途：ADR-0001 §4.3 的范围检查 —— 新增业务表若误入此域，测试应报错。
 *
 * ⚠ 幂等表（booking_idem）**不算**业务状态，故本函数对它返回 false；
 *   它由 `isBookingInfraTable()` 判定。两条口径分开，避免"域"这个词含混。
 */
public func isBookingDomainTable(name: String): Bool {
    for (t in BOOKING_DOMAIN_TABLES) {
        if (t == name) {
            return true
        }
    }
    return false
}

/* 判定某表是否属于号源域的**幂等基础设施**（booking_idem）。 */
public func isBookingInfraTable(name: String): Bool {
    for (t in BOOKING_INFRA_TABLES) {
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
 * 但它们是**基础设施**而非业务状态，所以与 BOOKING_* 分开列 ——
 * 这样"某张表归谁管"永远能从一个函数问出来，而不是靠读代码猜。
 */
public func isAuthTable(name: String): Bool {
    return name == TABLE_AUTH_USER || name == TABLE_AUTH_TOKEN
}

/*
 * 判定某表是否由 `BookingRepo` 写入（业务状态 + 幂等基础设施）。
 * 用途：ADR-0001 §4.3「范围锁死」的**完整**口径 —— 直接 SQL 只准落在这三张表上。
 */
public func isBookingOwnedTable(name: String): Bool {
    return isBookingDomainTable(name) || isBookingInfraTable(name)
}
