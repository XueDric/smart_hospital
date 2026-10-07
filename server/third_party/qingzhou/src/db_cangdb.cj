package qingzhou

import cangdb.*
import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * CangDB 后端（实现 DbBackend 接口）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 包装 cangdb.Db 为统一的 DbBackend 接口，供 RbacStore 使用。
 * 依赖外部 CangDB 静态库（libcangdb.a），不在默认编译范围内。
 */

/*
 * CangDB 后端：包装 cangdb.Db 为统一的 DbBackend 接口，供 RbacStore 使用。
 * CangDB 是嵌入式本地文件数据库（类似 SQLite 定位），零部署、随应用走。
 *
 * 依赖外部 CangDB 静态库（libcangdb.a），不在默认编译范围内：
 * 编译与运行示例见 build.sh 的 admin 目标与 examples/admin.env 的 db 项。
 */
public class CangDbBackend <: DbBackend {
    private let db: Db

    /* 打开（或首次创建）path 指向的 CangDB 本地数据库文件。 */
    public init(path: String) {
        db = Db(path)
    }

    /* 执行查询：遍历结果行，每列经 cangdb 的 valueStr 统一转成字符串。 */
    public func query(sql: String): DbResultSet {
        let rs = db.query(sql)
        let out = ArrayList<ArrayList<String>>()
        for (row in rs.rows) {
            let strRow = ArrayList<String>()
            for (v in row) {
                strRow.add(valueStr(v))
            }
            out.add(strRow)
        }
        return DbResultSet(out)
    }

    /* 执行写操作，直接透传 cangdb.Db.exec，返回受影响行数。 */
    public func exec(sql: String): Int64 {
        return db.exec(sql)
    }

    /* 确保表存在：CangDB 无 CREATE TABLE IF NOT EXISTS，先 findTable 检查再建。 */
    public func ensureTable(name: String, columns: String): Unit {
        if (db.findTable(name).isNone()) {
            db.exec("CREATE TABLE " + name + " (" + columns + ")")
        }
    }

    /* 关闭数据库文件句柄。 */
    public func close(): Unit {
        db.close()
    }

    /* 开启事务：透传 cangdb.Db.begin，已在事务中则抛异常。 */
    public func beginTransaction(): Unit {
        let _ = db.begin()
    }

    /* 提交事务：透传 cangdb.Db.commit（sync 落盘）。 */
    public func commitTransaction(): Unit {
        let _ = db.commit()
    }

    /* 回滚事务：透传 cangdb.Db.rollback（walRollback + 重载 catalog）。 */
    public func rollbackTransaction(): Unit {
        let _ = db.rollback()
    }
}
