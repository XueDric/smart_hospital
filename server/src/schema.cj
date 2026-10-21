/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * schema.cj —— 最小表集 DDL 与幂等迁移。
 *
 * 全表 utf8mb4：建连后必须 SET NAMES utf8mb4，否则 emoji 写入会持续报错。
 * 建表全部 IF NOT EXISTS；改既有表结构对存量库无效，必须在 migrateSchema 里显式补。
 * 号源扣减与归还靠 remain_num > 0 / < total_num 的原子 UPDATE，不用 version 乐观锁扣号。
 */

package qingzhou

/* 需要 ArrayList：仓颉 Array 不支持 +，合并 DDL 数组只能靠它。 */
import std.collection.*

/* 表名常量 */

/* 表名集中在此；必须避开搬迁前内存 Store 的表名（如 tokens），否则整库刷盘会争用同名表。 */
public let TABLE_DEPARTMENT: String = "department"
public let TABLE_DOCTOR: String = "doctor"
public let TABLE_SCHEDULE: String = "schedule"
public let TABLE_APPOINTMENT: String = "appointment"
public let TABLE_PATIENT: String = "patient"
public let TABLE_MEDICAL_RECORD: String = "medical_record"
/* 病历修订历史：一份病历 N 个版本，只能是一对多子表；临床数据不设 TTL。 */
public let TABLE_MEDICAL_RECORD_REVISION: String = "medical_record_revision"

/* 鉴权表：不叫 tokens（搬迁前内存 Store 占用该名）；auth_ 前缀标明鉴权域。 */
public let TABLE_AUTH_USER: String = "auth_user"
public let TABLE_AUTH_TOKEN: String = "auth_token"
/* 登录失败计数：账号不存在也必须计数，否则撞库不受限；键用登录名哈希，存储层无法区分存在与否。 */
public let TABLE_AUTH_ATTEMPT: String = "auth_login_attempt"

/* 唯二走直接 SQL 的业务表：schedule / appointment。 */
public let BOOKING_DOMAIN_TABLES: Array<String> = [TABLE_SCHEDULE, TABLE_APPOINTMENT]

/* 预问诊会话：医疗数据必须立即落库；form_json 存问诊单，加项不必改 DDL。 */
public let TABLE_PREVISIT: String = "previsit_session"

/* AI 配置 KV：不会有密钥——key_ref 只存 env:/file: 引用，validateKeyRef 拒绝其它形状。 */
public let TABLE_AI_SETTING: String = "ai_setting"

/* 分诊统计：只存时间、结论、科室名，不含任何患者标识；按 TRIAGE_STAT_TTL_DAYS 顺手清理。 */
public let TABLE_TRIAGE_STAT: String = "triage_stat"

/* 知识库两层：kb_doc 是人的维护单位、kb_chunk 是检索单位；改切块策略不动文档。 */
public let TABLE_KB_DOC: String = "kb_doc"
public let TABLE_KB_CHUNK: String = "kb_chunk"

/* 公告：title 唯一防同一事发两条；停用不删，published_at 支持预排期。 */
public let TABLE_NOTICE: String = "notice"

/* 全部业务表：库里有几张表只以这份清单为准。 */
public let ALL_TABLES: Array<String> = [
    TABLE_DEPARTMENT, TABLE_DOCTOR, TABLE_SCHEDULE,
    TABLE_APPOINTMENT, TABLE_PATIENT, TABLE_MEDICAL_RECORD,
    TABLE_AUTH_USER, TABLE_AUTH_TOKEN, TABLE_AUTH_ATTEMPT, TABLE_PREVISIT,
    TABLE_AI_SETTING, TABLE_TRIAGE_STAT,
    TABLE_KB_DOC, TABLE_KB_CHUNK, TABLE_NOTICE,
    TABLE_MEDICAL_RECORD_REVISION
]

/* DDL */

/*
 * 建表 DDL，全部 IF NOT EXISTS。金额/编号用 BIGINT 不用浮点；会建索引的列用 VARCHAR（TEXT 建唯一索引要前缀长度）。
 */
public let SCHEMA_DDL: Array<String> = [
    /* 科室：name 唯一（分诊按 name 查，重名会让推荐分裂）；code 唯一供对接。 */
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
    "UNIQUE KEY uk_department_name (name)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 医生：department_id 索引供科室下医生列表。 */
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

    /* 患者档案：只存最小必要字段，禁止存身份证号明文；phone 唯一。 */
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

    /* 排班/号源：扣减必须带 remain_num > 0、归还带 remain_num < total_num，绝不出现负数；version 只供管理端防覆盖。 */
    "CREATE TABLE IF NOT EXISTS schedule (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "doctor_id BIGINT NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "work_date VARCHAR(16) NOT NULL, " +
    "period VARCHAR(16) NOT NULL DEFAULT 'AM', " +
    "total_num BIGINT NOT NULL DEFAULT 0, " +
    "remain_num BIGINT NOT NULL DEFAULT 0, " +
    "version BIGINT NOT NULL DEFAULT 0, " +
    "enabled TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    /* 刻意不加 (doctor_id, work_date, period) 唯一键：work_date 可顺延，改期会撞库；重复排班由业务层 409 挡。 */
    "KEY idx_schedule_doctor_date (doctor_id, work_date)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 挂号单：visit_date 是快照不是外键，顺延排班不得改动已挂单。 */
    "CREATE TABLE IF NOT EXISTS appointment (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "schedule_id BIGINT NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    "doctor_id BIGINT NOT NULL, " +
    "department_id BIGINT NOT NULL, " +
    "visit_date VARCHAR(16) NOT NULL, " +
    "period VARCHAR(16) NOT NULL DEFAULT 'AM', " +
    "seq_no BIGINT NOT NULL DEFAULT 0, " +
    "status VARCHAR(16) NOT NULL DEFAULT 'booked', " +
    /* 就诊时间线三列：epoch 秒，0 = 未发生（不用 NULL，减法不变 NULL；1970 不可能是真实就诊时间）。 */
    "arrived_at BIGINT NOT NULL DEFAULT 0, " +
    "started_at BIGINT NOT NULL DEFAULT 0, " +
    "finished_at BIGINT NOT NULL DEFAULT 0, " +
    /* client_token 幂等键可空，退号置 NULL 释放；唯一索引允许多个 NULL，用空串会再撞唯一键。 */
    /* client_token 必须 COLLATE utf8mb4_bin：幂等键要字节精确，默认排序规则大小写不敏感会静默回放别人的单。 */
    "client_token VARCHAR(64) COLLATE utf8mb4_bin NULL DEFAULT NULL, " +
    /* slot_restored：第二次退号走幂等路径时如实返回上次结果，否则告警被一次无关重试抹掉。 */
    "slot_restored TINYINT NOT NULL DEFAULT 1, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "cancelled_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    /* 幂等必须按患者隔离：全局 UNIQUE(client_token) 会让患者 B 命中 A 的单（跨患者泄露）。 */
    "UNIQUE KEY uk_appointment_patient_token (patient_id, client_token), " +
    "KEY idx_appointment_patient (patient_id, status), " +
    "KEY idx_appointment_schedule (schedule_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 电子病历（七段式）：appointment_id 唯一，一单一份；P0 只建表。 */
    "CREATE TABLE IF NOT EXISTS medical_record (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "appointment_id BIGINT NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    "doctor_id BIGINT NOT NULL, " +
    "chief_complaint TEXT NOT NULL, " +
    "present_illness TEXT NOT NULL, " +
    "past_history TEXT NOT NULL, " +
    "allergy_history TEXT NOT NULL, " +
    "physical_exam TEXT NOT NULL, " +
    "diagnosis TEXT NOT NULL, " +
    "treatment TEXT NOT NULL, " +
    "status VARCHAR(16) NOT NULL DEFAULT 'draft', " +
    /* updated_by：病历必须能回答「谁写的」，锁定只锁内容锁不住责任。 */
    "updated_by BIGINT NOT NULL DEFAULT 0, " +
    /* previsit_ref：记哪些段来自患者自述；用 VARCHAR 而非 TEXT，MySQL 的 TEXT 不能带 DEFAULT。 */
    "previsit_ref VARCHAR(1024) NOT NULL DEFAULT '', " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_record_appointment (appointment_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /*
     * 修订历史：lock 落快照、reopen 落审计行（reason 必填），草稿保存不落版本；
     * sections_json 存全部七段含空段，diff 才能看出「从有到无」。
     */
    "CREATE TABLE IF NOT EXISTS medical_record_revision (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "record_id BIGINT NOT NULL, " +
    "appointment_id BIGINT NOT NULL, " +
    "version BIGINT NOT NULL, " +
    "status VARCHAR(16) NOT NULL, " +
    "sections_json TEXT NOT NULL, " +
    "operation VARCHAR(24) NOT NULL, " +
    "reason VARCHAR(255) NOT NULL DEFAULT '', " +
    /* 操作者 user_id 与 role 都记：账号被删或角色被改后仍能追责。 */
    "operator_user_id BIGINT NOT NULL DEFAULT 0, " +
    "operator_role VARCHAR(16) NOT NULL DEFAULT '', " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    /* 唯一键 (record_id, version)：并发两次 lock 算出同版本时由数据库挡下，插失败重算再插。 */
    "UNIQUE KEY uk_rev (record_id, version), " +
    "KEY idx_rev_appt (appointment_id, version)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 挂号幂等已由 (patient_id, client_token) 唯一索引覆盖；遗留 booking_idem 由迁移 DROP。 */

    /* 一个账号一个登录身份，login_name 唯一，三端共用按 role 区分；不合进 patient 表。 */
    "CREATE TABLE IF NOT EXISTS auth_user (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "login_name VARCHAR(64) NOT NULL, " +
    "role VARCHAR(16) NOT NULL, " +
    "ref_id BIGINT NOT NULL DEFAULT 0, " +
    "display_name VARCHAR(64) NOT NULL DEFAULT '', " +
    "pw_salt VARCHAR(64) NOT NULL, " +
    "pw_hash VARCHAR(128) NOT NULL, " +
    "pw_iter BIGINT NOT NULL DEFAULT 0, " +
    "status VARCHAR(16) NOT NULL DEFAULT 'active', " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (id), " +
    "UNIQUE KEY uk_auth_user_login (login_name)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 令牌 64 位 hex，服务端存映射（非无状态 JWT）可立即踢下线；user_id / expires_at 索引供列会话与清理。 */
    "CREATE TABLE IF NOT EXISTS auth_token (" +
    "token VARCHAR(64) NOT NULL, " +
    "user_id BIGINT NOT NULL, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "expires_at BIGINT NOT NULL DEFAULT 0, " +
    "last_renew_at BIGINT NOT NULL DEFAULT 0, " +
    /* device_id / device_name 由客户端自报，不可信：只用于会话列表展示，禁止用于授权判定。 */
    "device_id VARCHAR(64) NOT NULL DEFAULT '', " +
    "device_name VARCHAR(64) NOT NULL DEFAULT '', " +
    "last_seen_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (token), " +
    "KEY idx_auth_token_user (user_id), " +
    "KEY idx_auth_token_expires (expires_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /* 一行 = 一个登录名的失败状态；login_hash 存 SHA-256；idx 供按 last_fail_at 清过期行，否则表只增不减。 */
    "CREATE TABLE IF NOT EXISTS auth_login_attempt (" +
    "login_hash VARCHAR(64) NOT NULL, " +
    "fail_count BIGINT NOT NULL DEFAULT 0, " +
    "window_start BIGINT NOT NULL DEFAULT 0, " +
    "last_fail_at BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (login_hash), " +
    "KEY idx_auth_attempt_lastfail (last_fail_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /*
     * 分诊统计：只存时间、结论码、是否危急、命中科室名，不存主诉与任何患者标识；遥测列全是调用事实。
     * kb_doc_ids 存命中的文档 id（不是正文）：只存布尔值回答不了「结论是否被某篇过期文档带偏」。
     */
    "CREATE TABLE IF NOT EXISTS triage_stat (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "created_at BIGINT NOT NULL DEFAULT 0, " +
    "source VARCHAR(16) NOT NULL DEFAULT 'rules', " +
    "reason_code VARCHAR(32) NOT NULL DEFAULT '', " +
    "red_flag TINYINT NOT NULL DEFAULT 0, " +
    "department VARCHAR(64) NOT NULL DEFAULT '', " +
    "truncated TINYINT NOT NULL DEFAULT 0, " +
    "request_id VARCHAR(64) NOT NULL DEFAULT '', " +
    "model_id BIGINT NOT NULL DEFAULT 0, " +
    "model_name VARCHAR(64) NOT NULL DEFAULT '', " +
    "prompt_revision BIGINT NOT NULL DEFAULT 0, " +
    "elapsed_ms BIGINT NOT NULL DEFAULT 0, " +
    "degrade_reason VARCHAR(64) NOT NULL DEFAULT '', " +
    "used_kb TINYINT NOT NULL DEFAULT 0, " +
    "kb_doc_ids VARCHAR(255) NOT NULL DEFAULT '', " +
    "PRIMARY KEY (id), " +
    "KEY idx_triage_stat_at (created_at), " +
    "KEY idx_triage_stat_reason (reason_code), " +
    /* 排障按请求编号反查单次调用，缺它全表扫。 */
    "KEY idx_triage_stat_req (request_id)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS ai_setting (" +
    "k VARCHAR(64) NOT NULL, " +
    "v TEXT NOT NULL, " +
    "updated_at BIGINT NOT NULL DEFAULT 0, " +
    /* revision 只由保留行 __revision__ 持有（普通行 0，读 MAX）；寄生在会删的行上版本号会倒退。 */
    "revision BIGINT NOT NULL DEFAULT 0, " +
    "PRIMARY KEY (k)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS previsit_session (" +
    "id VARCHAR(64) NOT NULL, " +
    "patient_id BIGINT NOT NULL, " +
    /* appointment_id：0 = 未绑定；patient_id / appointment_id 两条索引供按人、按单取会话。 */
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

/* 知识库 DDL：单独数组、末尾拼接，建表入口一处不改。 */

public let KB_SCHEMA_DDL: Array<String> = [
    /* kb_doc（人维护的单位）：title 唯一防两份矛盾文档同时被召回；停用不删，历史检索仍可解释。 */
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
     * kb_chunk（检索单位）：embedding 存 JSON 数组且允许 NULL，无向量服务时仍可用关键词检索；
     * 唯一键 (doc_id, seq) 让重切块 upsert 不留幽灵行。
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

/* 公告 DDL */

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
    /* idx 按患者侧查询形状 (enabled, published_at) 建；列表不长，但查询形状与索引一致免回头改。 */
    "KEY idx_notice_visible (enabled, published_at)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* AI 模型配置 DDL */

/*
 * ai_model：多条命名配置；kind / temperature / max_tokens 用列才能在写入时校验，is_default「每个 kind 至多一条」是集合级不变量。
 * key_ref 只存引用，与 ai_setting 同一纪律。
 */
public let AI_MODEL_SCHEMA_DDL: Array<String> = [
    "CREATE TABLE IF NOT EXISTS ai_model (" +
    "id BIGINT NOT NULL AUTO_INCREMENT, " +
    "name VARCHAR(64) NOT NULL, " +
    "kind VARCHAR(16) NOT NULL, " +
    "provider VARCHAR(64) NOT NULL DEFAULT '', " +
    "base_url VARCHAR(512) NOT NULL, " +
    "model VARCHAR(128) NOT NULL, " +
    /* temperature 用 DOUBLE：范围 0..2 要在库层能拦住字符串。 */
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
    /* idx (kind, enabled, is_default)：解析「某 kind 的默认模型」正走这个形状。 */
    "KEY idx_ai_model_active (kind, enabled, is_default)" +
    ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/* 建表入口 */

/*
 * 幂等建表：逐条执行 SCHEMA_DDL 与知识库/公告/AI 模型三个子数组，返回实际执行语句数。
 */
public func ensureSchema(db: DbBackend): Int64 {
    var n: Int64 = 0
    for (sql in SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    for (sql in KB_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    for (sql in NOTICE_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    for (sql in AI_MODEL_SCHEMA_DDL) {
        db.exec(sql, Array<DbValue>())
        n = n + 1
    }
    return n
}

/*
 * 全部 DDL 的合并视图：任何「遍历所有 DDL」的地方必须用它，否则新增表只改一处会漏检。
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

/* 是否号源/挂号业务状态表（走直接 SQL 的那两张）；新增业务表误入此域应报错。 */
public func isBookingDomainTable(name: String): Bool {
    for (t in BOOKING_DOMAIN_TABLES) {
        if (t == name) {
            return true
        }
    }
    return false
}

/* 是否鉴权域表（auth_user / auth_token / auth_login_attempt）。 */
public func isAuthTable(name: String): Bool {
    return name == TABLE_AUTH_USER || name == TABLE_AUTH_TOKEN || name == TABLE_AUTH_ATTEMPT
}

/* 是否由 BookingRepo 独占写入：等价 isBookingDomainTable，函数名留作将来扩第二层。 */
public func isBookingOwnedTable(name: String): Bool {
    return isBookingDomainTable(name)
}

/* 迁移 */

/*
 * 幂等迁移，返回实际改动数：CREATE TABLE IF NOT EXISTS 对已有表无效，改既有表结构必须在此显式补；
 * ALTER / DROP 先查 information_schema，失败显式抛出不静默（静默失败会留下没有唯一约束的库）。
 */
public func migrateSchema(db: DbBackend): Int64 {
    var done: Int64 = 0

    /* 存量库补 medical_record.updated_by，否则整个病历域报 Unknown column。 */
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

    /* department.name 补唯一键；先查重名，有重名则报错并给处置，不自动改名（改名会改变分诊含义）。 */
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

    /* 补 appointment.slot_restored，默认 1（历史单不涉及归还）。 */
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

    /* client_token 改可空：先把历史空串归一成 NULL，再改列，顺序不能反。 */
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

    /* 释放已取消单占用的幂等键：只改代码不管老数据，会让同 token 重挂撞唯一键报 500。 */
    let staleCancelled = db.exec(
        "UPDATE appointment SET client_token = NULL " +
        "WHERE status = 'cancelled' AND client_token IS NOT NULL",
        Array<DbValue>())
    if (staleCancelled > 0) {
        done = done + 1
    }

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

    /* 唯一一处 DROP TABLE：删遗留 booking_idem（从不存业务数据，功能已被唯一索引覆盖）。 */
    let staleIdem = db.query(
        "SELECT COUNT(*) FROM information_schema.tables " +
        "WHERE table_schema = DATABASE() AND table_name = 'booking_idem'",
        Array<DbValue>())
    if (staleIdem.rowCount() > 0 && staleIdem.getInt(0, 0) > 0) {
        db.exec("DROP TABLE booking_idem", Array<DbValue>())
        done = done + 1
    }

    /* 存量库补 previsit_session.appointment_id，列与索引分两步判断。 */
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

    /* 存量库补 medical_record.previsit_ref，老行补空串（那批病历确实没记过来源）。 */
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

    /* 给存量已锁定病历补 v1 快照：只补没有任何修订的病历（NOT EXISTS），重复执行不覆盖新版本。 */
    let backfilled = emrBackfillRevisions(db)
    if (backfilled > 0) {
        done = done + 1
    }

    /* 补 triage_stat 遥测列：逐列判断，一次性 ALTER 会因某列已存在而整条失败，把其余列挡在门外。 */
    done = done + addTriageTelemetryColumns(db)

    /* 补 ai_setting.revision，默认 0 = 该行早于版本号上线。 */
    let hasRevision = db.query(
        "SELECT COUNT(*) FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'ai_setting' " +
        "AND column_name = 'revision'",
        Array<DbValue>())
    if (hasRevision.rowCount() > 0 && hasRevision.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE ai_setting ADD COLUMN revision BIGINT NOT NULL DEFAULT 0",
                Array<DbValue>())
        done = done + 1
    }

    /* 补 appointment 时间线三列：必须与 CREATE TABLE 一致，否则老库写入直接失败。 */
    done = done + addMissingColumns(db, "appointment", [
        "arrived_at BIGINT NOT NULL DEFAULT 0",
        "started_at BIGINT NOT NULL DEFAULT 0",
        "finished_at BIGINT NOT NULL DEFAULT 0"
    ])

    /*
     * client_token 改 utf8mb4_bin；只差大小写的重复键先打印并跳过，否则 MODIFY 撞唯一索引会让服务起不来。
     */
    let tokCollation = db.query(
        "SELECT COLLATION_NAME FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = 'appointment' " +
        "AND column_name = 'client_token'",
        Array<DbValue>())
    if (tokCollation.rowCount() > 0 && tokCollation.getString(0, 0) != "utf8mb4_bin") {
        let caseDup = db.query(
            "SELECT COUNT(*) FROM (SELECT patient_id, LOWER(client_token) AS t " +
            "FROM appointment WHERE client_token IS NOT NULL " +
            "GROUP BY patient_id, LOWER(client_token) HAVING COUNT(*) > 1) x",
            Array<DbValue>())
        if (caseDup.rowCount() > 0 && caseDup.getInt(0, 0) > 0) {
            println("[SCHEMA] ⚠ ⑭ 跳过：appointment 里存在**只差大小写**的 client_token 重复键，" +
                    "改列会撞唯一索引。请先合并这些行（幂等键应字节精确），再重启完成迁移。")
        } else {
            db.exec("ALTER TABLE appointment MODIFY COLUMN client_token " +
                    "VARCHAR(64) COLLATE utf8mb4_bin NULL DEFAULT NULL",
                    Array<DbValue>())
            done = done + 1
        }
    }

    /* DROP 掉误加的 uk_schedule_doctor_slot；这一步必须留着，否则跑过中间版本的库与新库约束不一致。 */
    let staleSlotIdx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'schedule' " +
        "AND index_name = 'uk_schedule_doctor_slot'",
        Array<DbValue>())
    if (staleSlotIdx.rowCount() > 0 && staleSlotIdx.getInt(0, 0) > 0) {
        db.exec("ALTER TABLE schedule DROP INDEX uk_schedule_doctor_slot",
                Array<DbValue>())
        println("[SCHEMA] ⑮ 已删除 schedule.uk_schedule_doctor_slot ——" +
                "该唯一键与「排班顺延」及现有夹具冲突，重复排班改由业务层拒绝（409）。")
        done = done + 1
    }

    return done
}

/* 给某表补缺的列，逐列判断；table 与 spec 只允许传本文件字面量，来自请求参数即注入。 */
private func addMissingColumns(db: DbBackend, table: String, cols: Array<String>): Int64 {
    var added: Int64 = 0
    for (spec in cols) {
        var name = spec
        let sp = spec.indexOf(" ")
        if (sp.isSome()) {
            name = spec[0..sp.getOrThrow()]
        }
        let rs = db.query(
            "SELECT COUNT(*) FROM information_schema.columns " +
            "WHERE table_schema = DATABASE() AND table_name = ? " +
            "AND column_name = ?",
            [DbStr(table), DbStr(name)])
        if (rs.rowCount() > 0 && rs.getInt(0, 0) == 0) {
            db.exec("ALTER TABLE " + table + " ADD COLUMN " + spec, Array<DbValue>())
            added = added + 1
        }
    }
    return added
}

/* 补 triage_stat 遥测列与 idx_triage_stat_req（排障反查入口）。 */
private func addTriageTelemetryColumns(db: DbBackend): Int64 {
    let cols = [
        "request_id VARCHAR(64) NOT NULL DEFAULT ''",
        "model_id BIGINT NOT NULL DEFAULT 0",
        "model_name VARCHAR(64) NOT NULL DEFAULT ''",
        "prompt_revision BIGINT NOT NULL DEFAULT 0",
        "elapsed_ms BIGINT NOT NULL DEFAULT 0",
        "degrade_reason VARCHAR(64) NOT NULL DEFAULT ''",
        "used_kb TINYINT NOT NULL DEFAULT 0",
        "kb_doc_ids VARCHAR(255) NOT NULL DEFAULT ''"
    ]
    let added = addMissingColumns(db, "triage_stat", cols)
    let idx = db.query(
        "SELECT COUNT(*) FROM information_schema.statistics " +
        "WHERE table_schema = DATABASE() AND table_name = 'triage_stat' " +
        "AND index_name = 'idx_triage_stat_req'",
        Array<DbValue>())
    if (idx.rowCount() > 0 && idx.getInt(0, 0) == 0) {
        db.exec("ALTER TABLE triage_stat ADD KEY idx_triage_stat_req (request_id)",
                Array<DbValue>())
    }
    return added
}
