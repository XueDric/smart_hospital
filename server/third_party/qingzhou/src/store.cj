package qingzhou

import std.collection.*
import std.convert.*

/*
 * SPDX-License-Identifier: MIT
 *
 * RBAC data access layer（基于 DbBackend 抽象接口）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 用户/角色/权限存储，依赖 DbBackend 接口而非具体数据库，
 * 从而支持 CangDB / MySQL / 未来后端切换（见 src/db.cj、src/db_*.cj）。
 *
 * 表结构（列名各后端一致，类型用通用 INT/TEXT）：
 *   users(id, username, password_hash, role_id)
 *   roles(id, name)
 *   permissions(id, code, name)
 *   role_permissions(role_id, permission_id)
 * RBAC 链：用户 -> 角色（单角色）-> 权限（多对多）。
 *
 * SQL 约定：只写最小公共子集（SELECT * / WHERE 等值 / INSERT VALUES /
 * UPDATE SET / DELETE WHERE / ORDER BY），保证各后端可执行。
 * 凡含外部输入的 SQL 一律走参数化查询——
 * SQL 用 ? 占位符 + DbValue 参数数组（DbBackend.query/exec 的重载，
 * 见 src/db.cj），不再手写 sqlQuote 拼接。占位符按序绑定，字符串
 * 由框架统一转义、数字原样，从根上消除单引号注入（旧版登录路径
 * 可被 ' OR '1'='1 绕过）。
 */

/* users 表行（列序：id, username, password_hash, role_id）。 */
public class UserRow {
    public let id: Int64
    public let username: String
    public let passwordHash: String
    public let roleId: Int64
    public init(id: Int64, username: String, passwordHash: String, roleId: Int64) {
        this.id = id
        this.username = username
        this.passwordHash = passwordHash
        this.roleId = roleId
    }
}

/* roles 表行（列序：id, name）。 */
public class RoleRow {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

/* permissions 表行（列序：id, code, name）。 */
public class PermRow {
    public let id: Int64
    public let code: String
    public let name: String
    public init(id: Int64, code: String, name: String) {
        this.id = id
        this.code = code
        this.name = name
    }
}

/*
 * RBAC 存储：用户/角色/权限的增删查与权限判定。
 * 全部 SQL 经构造时传入的 DbBackend 执行，自身不感知具体数据库；
 * 首次打开自动建表（ensureSchema）并灌入种子数据（seed）。
 */
public class RbacStore {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
        ensureSchema()
        seed()
    }

    /* 建表（列名各后端一致，类型用 INT/TEXT 通用类型）。 */
    private func ensureSchema(): Unit {
        db.ensureTable("users", "id INT, username TEXT, password_hash TEXT, role_id INT")
        db.ensureTable("roles", "id INT, name TEXT")
        db.ensureTable("permissions", "id INT, code TEXT, name TEXT")
        db.ensureTable("role_permissions", "role_id INT, permission_id INT")
        // B-3：users.username 建唯一索引（数据库层兜底，防并发重复插入）。
        // 方言下沉到后端（CangDB 无前缀 / MySQL 前缀 255，见 DbBackend.
        // ensureUniqueIndex）；重复建索引时后端抛「已存在」异常，忽略（幂等）。
        try {
            db.ensureUniqueIndex("users", "username")
        } catch (e: Exception) {
            // 索引已存在，忽略
        }
    }

    /* 首次启动灌入种子数据：admin/user 两个角色、6 个权限、2 个用户。 */
    private func seed(): Unit {
        if (db.query("SELECT * FROM roles").rowCount() == 0) {
            db.exec("INSERT INTO roles VALUES (1, 'admin')")
            db.exec("INSERT INTO roles VALUES (2, 'user')")
            db.exec("INSERT INTO permissions VALUES (1, 'user:list', '查看用户')")
            db.exec("INSERT INTO permissions VALUES (2, 'user:create', '创建用户')")
            db.exec("INSERT INTO permissions VALUES (3, 'user:delete', '删除用户')")
            db.exec("INSERT INTO permissions VALUES (4, 'role:list', '查看角色')")
            db.exec("INSERT INTO permissions VALUES (5, 'perm:list', '查看权限')")
            db.exec("INSERT INTO permissions VALUES (6, 'dashboard:view', '查看仪表盘')")
            // admin 角色拥有全部 6 个权限（注意：仓颉 .. 是半开区间，闭区间须用 ..=）
            for (i in 1..=6) {
                db.exec("INSERT INTO role_permissions VALUES (1, ${i})")
            }
            // user 角色仅有 dashboard:view
            db.exec("INSERT INTO role_permissions VALUES (2, 6)")
        }
        if (db.query("SELECT * FROM users").rowCount() == 0) {
            // admin / admin123，角色 admin
            let adminHash = hashPassword("admin123", "qz2026", 1000)
            db.exec("INSERT INTO users VALUES (?, ?, ?, ?)", [DbInt(1), DbStr("admin"), DbStr(adminHash), DbInt(1)])
            // user / user123，角色 user
            let userHash = hashPassword("user123", "qz2026", 1000)
            db.exec("INSERT INTO users VALUES (?, ?, ?, ?)", [DbInt(2), DbStr("user"), DbStr(userHash), DbInt(2)])
        }
    }

    /* 按用户名查用户，不存在返回 None。 */
    public func findUserByUsername(username: String): ?UserRow {
        // username 来自登录表单，走参数化查询（? + DbStr），
        // 框架统一转义，杜绝 ' OR '1'='1 注入。
        let rs = db.query("SELECT * FROM users WHERE username = ?", [DbStr(username)])
        if (rs.rowCount() == 0) {
            return None
        }
        return Some(toUserRow(rs, 0))
    }

    /* 按 id 查用户，不存在返回 None。 */
    public func findUserById(id: Int64): ?UserRow {
        let rs = db.query("SELECT * FROM users WHERE id = ${id}")
        if (rs.rowCount() == 0) {
            return None
        }
        return Some(toUserRow(rs, 0))
    }

    /* 全部用户，按 id 升序。 */
    public func listUsers(): ArrayList<UserRow> {
        let rs = db.query("SELECT * FROM users ORDER BY id")
        let out = ArrayList<UserRow>()
        for (i in 0..rs.rowCount()) {
            out.add(toUserRow(rs, i))
        }
        return out
    }

    /*
     * 创建用户并返回分配的 id：在事务内「查重 + 插入」，
     * username 已存在时抛 IllegalArgumentException（消除旧版「唯一性由
     * 调用方保证」的 TOCTOU 缺陷）；数据库层另有唯一索引兜底（见
     * ensureSchema）。参数合法性（如口令已哈希）由调用方保证。
     */
    public func createUser(username: String, passwordHash: String, roleId: Int64): Int64 {
        let id = nextUserId()
        db.withTransaction({ =>
            let rs = db.query("SELECT * FROM users WHERE username = ?", [DbStr(username)])
            if (rs.rowCount() > 0) {
                throw IllegalArgumentException("用户名已存在: ${username}")
            }
            db.exec("INSERT INTO users VALUES (?, ?, ?, ?)", [DbInt(id), DbStr(username), DbStr(passwordHash), DbInt(roleId)])
        })
        return id
    }

    /*
     * 修改用户密码：生成新随机盐并哈希
     * newPassword，按 id 更新 password_hash。返回是否真的更新了行
     * （用户不存在返回 false）。旧版只有种子口令而无任何改密入口，
     * 默认口令只能永久裸奔。
     */
    public func changePassword(id: Int64, newPassword: String): Bool {
        let newHash = hashPassword(newPassword, randomHex(16), 1000)
        return db.exec("UPDATE users SET password_hash = ? WHERE id = ?", [DbStr(newHash), DbInt(id)]) > 0
    }

    /* 按 id 删除用户，返回是否真的删除了数据。 */
    public func deleteUser(id: Int64): Bool {
        return db.exec("DELETE FROM users WHERE id = ${id}") > 0
    }

    /* 全部角色，按 id 升序。 */
    public func listRoles(): ArrayList<RoleRow> {
        let rs = db.query("SELECT * FROM roles ORDER BY id")
        let out = ArrayList<RoleRow>()
        for (i in 0..rs.rowCount()) {
            out.add(RoleRow(rs.getInt(i, 0), rs.getString(i, 1)))
        }
        return out
    }

    /* 全部权限，按 id 升序。 */
    public func listPermissions(): ArrayList<PermRow> {
        let rs = db.query("SELECT * FROM permissions ORDER BY id")
        let out = ArrayList<PermRow>()
        for (i in 0..rs.rowCount()) {
            out.add(PermRow(rs.getInt(i, 0), rs.getString(i, 1), rs.getString(i, 2)))
        }
        return out
    }

    /* 角色名（id -> name），不存在返回空串。 */
    public func roleNameOf(roleId: Int64): String {
        let rs = db.query("SELECT * FROM roles WHERE id = ${roleId}")
        if (rs.rowCount() == 0) {
            return ""
        }
        return rs.cell(0, 1)
    }

    /* 用户拥有的权限码集合：用户 -> 角色 -> 权限，分步查询 + 应用层组合。 */
    public func permissionCodesOf(userId: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        let rs1 = db.query("SELECT * FROM users WHERE id = ${userId}")
        if (rs1.rowCount() == 0) {
            return out
        }
        let roleId = rs1.getInt(0, 3)
        let rs2 = db.query("SELECT * FROM role_permissions WHERE role_id = ${roleId}")
        for (i in 0..rs2.rowCount()) {
            let pid = rs2.getInt(i, 1)
            let rs3 = db.query("SELECT * FROM permissions WHERE id = ${pid}")
            if (rs3.rowCount() > 0) {
                out.add(rs3.getString(0, 1))
            }
        }
        return out
    }

    /* 判断用户是否拥有指定权限码（内部走 permissionCodesOf 全量比对）。 */
    public func hasPermission(userId: Int64, code: String): Bool {
        let codes = permissionCodesOf(userId)
        for (c in codes) {
            if (c == code) {
                return true
            }
        }
        return false
    }

    /* 关闭底层后端连接（进程退出前调用，见 examples/admin.cj 优雅关闭流程）。 */
    public func close(): Unit {
        db.close()
    }

    /* ---------- internals ---------- */

    /* 结果集第 i 行 -> UserRow（依赖 ensureSchema 固定的列序）。
       v0.8（C-3）：改用 DbResultSet 类型化取值（getInt/getString）。 */
    private func toUserRow(rs: DbResultSet, i: Int64): UserRow {
        return UserRow(
            rs.getInt(i, 0),
            rs.getString(i, 1),
            rs.getString(i, 2),
            rs.getInt(i, 3)
        )
    }

    /* 新用户 id = 当前最大 id + 1（单实例顺序写场景足够；各后端通用写法）。 */
    private func nextUserId(): Int64 {
        let rs = db.query("SELECT * FROM users ORDER BY id DESC")
        if (rs.rowCount() == 0) {
            return 1
        }
        return rs.getInt(0, 0) + 1
    }
}
