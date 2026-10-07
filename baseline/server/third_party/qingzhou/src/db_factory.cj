package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 数据存储工厂：按 DSN 选择后端。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * DSN 格式：
 *   "cangdb:admin.cjdb"      -> CangDB 嵌入式（本地文件路径）
 *   "admin.cjdb"             -> 同 CangDB（无前缀默认按 CangDB 文件路径）
 *   "mysql://user:pass@host:3306/db" -> MySQL（
 *                              编译时需带上 src/db_mysql.cj，运行时需
 *                              可用的驱动，见 docs/DATABASE.md）
 *
 * 切换数据库只需改 DSN，业务代码零改动。新增后端时在此函数加一个分支，
 * 并实现对应的 DbBackend（参考 src/db_cangdb.cj / src/db_mysql.cj）。
 *
 * 用法：
 *   let store = openStore("cangdb:admin.cjdb")
 *   ...  // 业务侧只面向 RbacStore，与具体后端解耦
 *   store.close()
 */
public func openStore(dsn: String): RbacStore {
    // "cangdb:路径" 前缀：显式选择 CangDB 嵌入式后端，冒号后是数据文件路径
    if (dsn.startsWith("cangdb:")) {
        return RbacStore(CangDbBackend(dsn[7..]))
    }
    // "mysql://..."：解析 DSN 并构造 MySqlBackend。
    if (dsn.startsWith("mysql://")) {
        return RbacStore(parseMySqlDsn(dsn))
    }
    // 兼容 "mysql:"（不带 //）写法：补全成标准形态再解析
    if (dsn.startsWith("mysql:")) {
        return RbacStore(parseMySqlDsn("mysql://" + dsn[6..]))
    }
    // 无前缀：按裸文件路径处理，默认走 CangDB（最常用路径保持零配置）
    return RbacStore(CangDbBackend(dsn))
}

/*
 * 按 DSN 构造单个后端（不包 RbacStore）：openPool 的连接工厂。
 * 与 openStore 的 DSN 解析完全一致，只是返回裸 DbBackend 而非 RbacStore，
 * 供连接池按需创建新连接。
 */
func newBackend(dsn: String): DbBackend {
    if (dsn.startsWith("cangdb:")) {
        return CangDbBackend(dsn[7..])
    }
    if (dsn.startsWith("mysql://")) {
        return parseMySqlDsn(dsn)
    }
    if (dsn.startsWith("mysql:")) {
        return parseMySqlDsn("mysql://" + dsn[6..])
    }
    return CangDbBackend(dsn)
}

/*
 * 打开连接池：按 DSN 构造一个 SimpleDbPool，连接按需创建、用后复用。
 *
 * 与 openStore 的差异：openStore 返回单个 RbacStore（单连接，进程内长期
 * 复用），openPool 返回连接池（多连接，并发请求各自 borrow 独占连接，
 * 用后归还）。并发场景（尤其 withTransaction 事务）下应优先用池，避免
 * 单连接上事务串线或驱动非线程安全导致的数据竞争。
 *
 * 用法：
 *   let pool = openPool("mysql://root:pass@127.0.0.1:3306/app_db", 8)
 *   let be = pool.acquire()
 *   let store = RbacStore(be)      // 借出的连接直接喂给 RbacStore
 *   ...  // 用完
 *   store.close()                  // 或 pool.release(be)
 *   pool.close()
 *
 * capacity 是「空闲连接保有上限」（见 SimpleDbPool），非并发硬上限。
 */
public func openPool(dsn: String, capacity: Int64): SimpleDbPool {
    return SimpleDbPool({ => newBackend(dsn) }, capacity)
}

/*
 * 解析 mysql://user:pass@host:port/db 并构造 MySqlBackend。
 *
 * 规则（与 docs/DATABASE.md 的 DSN 表一致）：
 *   - userinfo 与 host 以「最后一个 @」分割（口令允许含 @）；
 *   - user 与 password 以「第一个 :」分割（用户名不允许含 :）；
 *   - host:port 以「最后一个 :」分割，端口缺省 3306；
 *   - /db 必填（MySqlBackend 需要库名）。
 *
 * 错误消息统一经 redactDsn 脱敏，口令绝不落日志。
 */
func parseMySqlDsn(dsn: String): MySqlBackend {
    let rest = dsn["mysql://".size..]

    let (userinfo, hostPart) = match (rest.lastIndexOf("@")) {
        case Some(i) => (rest[0..i], rest[i + 1..])
        case None => throw Exception("mysql DSN 格式不对，应形如 mysql://user:pass@host:3306/dbname：${redactDsn(dsn)}")
    }
    let (user, password) = match (userinfo.indexOf(":")) {
        case Some(i) => (userinfo[0..i], userinfo[i + 1..])
        case None => (userinfo, "")
    }
    let (hostPort, database) = match (hostPart.indexOf("/")) {
        case Some(i) => (hostPart[0..i], hostPart[i + 1..])
        case None => throw Exception("mysql DSN 缺少库名，应以 /dbname 结尾：${redactDsn(dsn)}")
    }
    if (hostPort.size == 0) {
        throw Exception("mysql DSN 缺少主机名：${redactDsn(dsn)}")
    }

    var host = hostPort
    var port: Int64 = 3306
    match (hostPort.lastIndexOf(":")) {
        case Some(i) =>
            host = hostPort[0..i]
            match (parseInt64OrNone(hostPort[i + 1..])) {
                case Some(p) => port = p
                case None => throw Exception("mysql DSN 端口不是合法整数：${redactDsn(dsn)}")
            }
        case None => ()
    }
    return MySqlBackend(host, port, user, password, database)
}

/*
 * DSN 脱敏：丢弃 user:pass@ 段（最后一个 @ 之前的内容全部遮掉），
 * 只保留 host 部分，供异常消息安全展示。
 */
func redactDsn(dsn: String): String {
    match (dsn.lastIndexOf("@")) {
        case Some(i) => return "***@" + dsn[i + 1..]
        case None => return dsn
    }
}
