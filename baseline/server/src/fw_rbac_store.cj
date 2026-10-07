/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+40 / -1（git log --author 统计；标注日期 2026-09-18）
 * 算法相关：新增 usernameTaken() 等：RBAC 数据层的重名/存在性判定逻辑
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 【本地适配 · 暂时性】轻舟 RbacStore 的数据层替换 —— 2026-09-14
 *
 * 背景
 *   轻舟升级到 3ea387e 后（e072980 仍然如此），框架的 src/store.cj 用 CangDB 存 RBAC 数据
 *   （users / roles / permissions / role_permissions），而沧海 CangDB 虽已开源（gitcode.com/BIT-FSSLab/CangDB），
 *   我们验证到的 1.0.5 版本却与 cjc 1.1.3 不兼容（**编译通过、运行超时**），
 *   于是 `import cangdb.*` 在我们这条构建里没有可用实现，整个构建被卡住。
 *
 * 本文件的定位
 *   把那个数据层**对齐到我们项目自己的接口与原则**：
 *     · 持久化用**文件存储**（内存 + 原子落盘 JSON，先写 .tmp 再 rename），
 *       与 server/src/store.cj 完全同一套做法；项目原则是「不用数据库」（README 设计原则）
 *     · 公开 API 与轻舟原版**逐一对齐**（同名同签名），所以 rbac.cj 与 examples/admin.cj
 *       不需要任何改动就能编、能用
 *   即：只换数据层，不动调用方。
 *
 * 怎么撤销（等 CangDB 有与 cjc 1.1.3 兼容的版本之后）
 *   1. 删掉本文件
 *   2. server/build.ps1 的框架文件排除表去掉 'store.cj'
 *   3. 把轻舟的 src/store.cj 放回默认构建
 *
 * ⚠ 与 DEF-1 补丁同一个教训：这是**跟着上游文件走的适配**，上游再改 store.cj 时
 *    本文件会静默过期。升级轻舟后请重跑全部测试（单测 / 冒烟 / TLS / 契约 / 后台端到端，
 *    最后一套 = `build.ps1 -Target admin` + `tests/admin-check.ps1`）。
 *
 * 与轻舟原版的差异（**三处**语义变化，必须知道 —— 2026-09-17 补第三处）
 *   · 原版 role_permissions 是一张 JOIN 表；本实现内部用 HashMap<roleId, Array<permId>>
 *     表达同一事实（对外 API 不暴露该表，行为一致）
 *   · close() 在原版是关库；本实现是"落盘 + 无操作"（文件存储没有连接可关）
 *   · **createUser() 会拒绝重名**（抛出异常）。原版不校验，我们这里校验 ——
 *     理由见 createUser() 的长注释（重名会让 findUserByUsername 的结果变成不确定的）。
 *     取"抛异常"而不是"改签名"是为了不动其它调用方与单测。
 *
 * 自包含（2026-09-16）
 *   本文件**只依赖框架与 std**：JSON 读写用框架自带的 `jsonGetInt64` / `jsonGetStr` /
 *   `JsonInt` / `JsonString`，不引用 `server/src` 里的 jsonw.cj —— 这样它可以直接当作
 *   "上游 store.cj 的替身"用于**任何**基于轻舟的构建（例如 `examples/admin.cj` 那个
 *   后台管理示例），而不必连带编入我们服务端的其它文件。
 *
 * 另外两条读码时最容易误会的地方（2026-09-16 补记）
 *   · **种子口令哈希不是我们那套**：`seed()` 里的 admin/user 用的是轻舟 `security.cj` 的
 *     `hashPassword`（迭代 SHA-256、格式 `salt$rounds$hash`），**不是** `server/src/auth.cj`
 *     的 `pbkdf2Sha256`（PBKDF2-HMAC-SHA256）。所以那两条种子记录**用 `verifyPw` 验不了**，
 *     反之亦然 —— 两套口令体系并存，别交叉调用。`Member` 表走 PBKDF2，这里只服务
 *     轻舟 RBAC 自己的 `findUserByUsername` / `hasPermission`。
 *   · **灌种子的判据是"文件不存在"**，不是"roles 为空"（见 `init` 的注释）：
 *     文件存在但内容为空时**保持为空**（fail closed），绝不重建种子覆盖用户数据。
 *   · `nextUserId()` 取 `max(id) + 1`，与 AUTOINCREMENT 不同：删掉最大 id 后再建用户会**复用**该 id。
 *     本层目前没有审计/引用它的地方，故未改；若将来被真正用起来，应改成持久化计数器。
 */

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/* 与轻舟 src/store.cj 完全一致的三个行类型。 */
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

public class RoleRow {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

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
 * 首次建库时要用的种子口令（N-29，2026-09-17 新增）。
 *
 * 为什么要显式传进来：种子账号原先写死 `admin123` / `user123` —— 那是一对
 * **公开在仓库里、且文档还会照抄给你**的默认口令，而运维台监听 0.0.0.0，
 * 于是"能连上 3000 端口"就等于"能读整个社团库、并能通过 /api/club/session
 * 拿到 ops 令牌去接管会长账号"（完整复现见 docs/code-review.md 的 N-29）。
 *
 * 约定：
 *   · 字段**给了值**（来自 admin.env 的 admin_pass / user_pass）→ 用它；
 *   · 字段**为空** → seed() 随机生成一个并**写回本对象**，调用方据此打印/落盘。
 * 于是默认值不再是任何固定字符串。
 */
public class SeedCreds {
    public var adminPass: String = ""
    public var userPass: String = ""

    public init() {}
}

/*
 * RBAC 数据访问层。公开 API 与轻舟 src/store.cj 的 RbacStore 逐一对齐。
 * path：JSON 文件路径（相对 cwd），与我们的数据目录约定一致。
 */
public class RbacStore {
    private let path: String
    private var users: HashMap<Int64, UserRow> = HashMap<Int64, UserRow>()
    private var roles: HashMap<Int64, RoleRow> = HashMap<Int64, RoleRow>()
    private var perms: HashMap<Int64, PermRow> = HashMap<Int64, PermRow>()
    /* roleId -> 该角色拥有的 permission id 列表（替代原版的 role_permissions JOIN 表） */
    private var rolePerms: HashMap<Int64, ArrayList<Int64>> = HashMap<Int64, ArrayList<Int64>>()

    /* 不带初始口令：种子口令一律随机生成（单测与"只想读一个已有库"的场景用它）。 */
    public init(path: String) {
        this.path = path
        openStore(SeedCreds())
    }

    /* 带初始口令：运维台入口用它把 admin.env 里的 admin_pass / user_pass 传进来（N-29）。 */
    public init(path: String, creds: SeedCreds) {
        this.path = path
        openStore(creds)
    }

    private func openStore(creds: SeedCreds): Unit {
        /*
         * 灌种子的判据是「**文件不存在**」，不是「roles 为空」（2026-09-16 修）。
         *
         * 原先写的是 `if (exists(path)) { load() }` 之后再 `if (roles.size == 0) { seed(); save() }`，
         * 于是有一种会**静默覆盖真实数据**的组合：
         *   文件存在（甚至解析成功）但 `roles` 键缺失或为空 —— 例如手工编辑过、
         *   或将来某次改动把键名写错 —— roles.size == 0 被判成"首次打开"，
         *   接着 seed() + save() 把种子数据写回去，**用户真实数据就没了**。
         * 文件存在却读不出内容，正确的反应是「保持为空、交给调用方判断」（fail closed），
         * 而不是替用户重建一份。
         *
         * 注意 `load()` 对**解析失败**已经是 fail-fast（抛异常拒绝启动），
         * 这里补的是"解析成功但内容为空"这条缝。
         */
        let fresh = !exists(this.path)
        if (!fresh) {
            load()
        }
        if (fresh) {
            seed(creds)
            save()
        }
    }

    /* ===================== 与上游一致的公开 API ===================== */

    public func findUserByUsername(username: String): ?UserRow {
        for ((_k, u) in users) {
            if (u.username == username) {
                return Some(u)
            }
        }
        return None
    }

    /*
     * 用户名是否已被占用（2026-09-17 新增）。
     *
     * 为什么要它：`findUserByUsername()` 在 HashMap 上取**首个匹配** —— 一旦库里有两条同名记录，
     * "登录时用的是哪一个"就取决于 HashMap 的遍历顺序，是**不确定**的：后建的那个可能永远登不进去
     * （而它明明出现在用户列表里、也能被单独删除）。这不是"多一条脏数据"，而是"账号看着存在、
     * 行为随机"，排查时极难定位。调用方（运维台的 POST /api/users）用它先给一个明确的 400。
     *
     * 规模：用户数在个位到十位量级（运维台自己的账号），线性扫描足够，不必另建索引。
     */
    public func usernameTaken(username: String): Bool {
        for ((_k, u) in users) {
            if (u.username == username) {
                return true
            }
        }
        return false
    }

    public func findUserById(id: Int64): ?UserRow {
        return users.get(id)
    }

    public func listUsers(): ArrayList<UserRow> {
        let out = ArrayList<UserRow>()
        for ((_k, u) in users) {
            out.add(u)
        }
        return sortedUsers(out)
    }

    /*
     * 建用户（**重名直接拒绝**，2026-09-17 修）。
     *
     * 原先这里不校验重名，调用方也大多不校验，于是"建第二个 admin"这件事既不会报错、
     * 也不会立刻显出问题 —— 它只是让**登录变成不确定的**（见 usernameTaken 的注释）。
     * 上游轻舟的 store.cj 同样不校验，所以这不属于"跟着上游走"的那类差异，而是本适配层
     * 自己该守的一条不变式：**用户名在库里唯一**。
     *
     * 为什么用抛异常而不是返回错误码：公开 API 与上游逐一对齐是本文件的立身之本
     * （见文件头的"公开 API 与轻舟原版逐一对齐"），改签名会让 admin.cj / 单测 / 调用方全部要动。
     * 抛异常是"fail loud"：调用方忘了预检查时也不会写出一个重名库，只会在日志里留下一句明确的错。
     * ⚠ 调用方若要给出友好的 4xx，应先用 usernameTaken() 预检查（运维台的 POST /api/users 就是这么做的），
     * 别把这条异常当成常规控制流 —— 它兜的是并发与"将来新写的调用方"。
     */
    public func createUser(username: String, passwordHash: String, roleId: Int64): Int64 {
        if (usernameTaken(username)) {
            throw Exception("用户名已存在：${username}（username must be unique）")
        }
        let id = nextUserId()
        users[id] = UserRow(id, username, passwordHash, roleId)
        /*
         * 落盘失败要**回滚内存**（2026-09-18 修）。原先 save() 抛异常时这条记录已经留在
         * users 里，于是出现"内存里有、盘上没有"的分裂状态，症状很误导：
         *   · 调用方看到异常，容易把它报成重名（运维台原先就是这么做的）；
         *   · 该账号在**重启前居然能登录**（findUserByUsername 走内存），重启后又凭空消失；
         *   · 重试同一个用户名会被 usernameTaken() 拦成"已存在"，用户以为是自己名字的问题。
         * 现在 save() 一失败就把这条摘掉再抛，内存与磁盘保持一致 ——
         * save() 自己是 .tmp + rename 的原子写，盘上仍是旧的完整内容，不会留下半截文件。
         * nextUserId() 只是"取当前 max+1"，不落盘，回滚后跳过的 id 号无害。
         */
        try {
            save()
        } catch (e: Exception) {
            users.remove(id)
            throw e
        }
        return id
    }

    public func deleteUser(id: Int64): Bool {
        if (!users.contains(id)) {
            return false
        }
        users.remove(id)
        save()
        return true
    }

    public func listRoles(): ArrayList<RoleRow> {
        let out = ArrayList<RoleRow>()
        for ((_k, r) in roles) {
            out.add(r)
        }
        return sortedRoles(out)
    }

    public func listPermissions(): ArrayList<PermRow> {
        let out = ArrayList<PermRow>()
        for ((_k, p) in perms) {
            out.add(p)
        }
        return sortedPerms(out)
    }

    public func roleNameOf(roleId: Int64): String {
        match (roles.get(roleId)) {
            case Some(r) => return r.name
            case None => return ""
        }
    }

    /* 用户 -> 角色 -> 权限，与原版一样是分步查询 + 应用层组合。 */
    public func permissionCodesOf(userId: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        let u = match (users.get(userId)) {
            case Some(x) => x
            case None => return out
        }
        match (rolePerms.get(u.roleId)) {
            case Some(pids) =>
                for (pid in pids) {
                    match (perms.get(pid)) {
                        case Some(p) => out.add(p.code)
                        case None => ()
                    }
                }
            case None => ()
        }
        return out
    }

    public func hasPermission(userId: Int64, code: String): Bool {
        for (c in permissionCodesOf(userId)) {
            if (c == code) {
                return true
            }
        }
        return false
    }

    /* 原版关库；文件存储没有连接可关，这里落盘即可。 */
    public func close(): Unit {
        save()
    }

    /* ===================== 种子数据（与上游同一份） ===================== */

    private func seed(creds: SeedCreds): Unit {
        roles[1] = RoleRow(1, "admin")
        roles[2] = RoleRow(2, "user")
        perms[1] = PermRow(1, "user:list", "查看用户")
        perms[2] = PermRow(2, "user:create", "创建用户")
        perms[3] = PermRow(3, "user:delete", "删除用户")
        perms[4] = PermRow(4, "role:list", "查看角色")
        perms[5] = PermRow(5, "perm:list", "查看权限")
        perms[6] = PermRow(6, "dashboard:view", "查看仪表盘")
        /* admin 角色拥有全部 6 个权限 */
        let adminPerms = ArrayList<Int64>()
        var i: Int64 = 1
        while (i <= 6) {
            adminPerms.add(i)
            i += 1
        }
        rolePerms[1] = adminPerms
        /* user 角色仅有 dashboard:view */
        let userPerms = ArrayList<Int64>()
        userPerms.add(6)
        rolePerms[2] = userPerms
        /*
         * 两个内置账号。口令**不再写死**（N-29）：调用方给了就用给的，没给就随机生成，
         * 并把生成值写回 creds，由调用方打印一次 / 落盘到 admin.env。
         * 哈希仍与原版同盐同轮数（`security.cj` 的 hashPassword）。
         */
        if (creds.adminPass.size == 0) {
            creds.adminPass = randomHex(8)      /* 16 个十六进制字符 */
        }
        if (creds.userPass.size == 0) {
            creds.userPass = randomHex(8)
        }
        users[1] = UserRow(1, "admin", hashPassword(creds.adminPass, "qz2026", 1000), 1)
        users[2] = UserRow(2, "user", hashPassword(creds.userPass, "qz2026", 1000), 2)
    }

    private func nextUserId(): Int64 {
        var mx: Int64 = 0
        for ((k, _u) in users) {
            if (k > mx) {
                mx = k
            }
        }
        return mx + 1
    }

    /* 原版是 `ORDER BY id`：这里按 id 升序。规模很小，插入排序足够。 */
    private func sortedUsers(a: ArrayList<UserRow>): ArrayList<UserRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<UserRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    private func sortedRoles(a: ArrayList<RoleRow>): ArrayList<RoleRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<RoleRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    private func sortedPerms(a: ArrayList<PermRow>): ArrayList<PermRow> {
        let arr = a.toArray()
        var i: Int64 = 1
        while (i < arr.size) {
            let cur = arr[i]
            var j = i - 1
            while (j >= 0 && arr[j].id > cur.id) {
                arr[j + 1] = arr[j]
                j -= 1
            }
            arr[j + 1] = cur
            i += 1
        }
        let out = ArrayList<PermRow>()
        for (x in arr) {
            out.add(x)
        }
        return out
    }

    /* ===================== 文件存储（与 server/src/store.cj 同一套做法） ===================== */

    private func load(): Unit {
        let text = String.fromUtf8(File.readFrom(path))
        var root: ?JsonObject = None
        try {
            root = Some(JsonValue.fromStr(text).asObject())
        } catch (e: Exception) {
            root = None
        }
        var r: JsonObject
        match (root) {
            case Some(x) => r = x
            /* 与 store.cj 同一口径：解析失败绝不当成空库，否则下次保存会覆盖真实数据 */
            case None => throw Exception("RBAC 数据文件无法解析：${path}")
        }
        users = HashMap<Int64, UserRow>()
        roles = HashMap<Int64, RoleRow>()
        perms = HashMap<Int64, PermRow>()
        rolePerms = HashMap<Int64, ArrayList<Int64>>()

        for (o in objArr(r, "users")) {
            let id = (jsonGetInt64(o, "id") ?? 0)
            users[id] = UserRow(id, (jsonGetStr(o, "username") ?? ""), (jsonGetStr(o, "password_hash") ?? ""),
                (jsonGetInt64(o, "role_id") ?? 0))
        }
        for (o in objArr(r, "roles")) {
            let id = (jsonGetInt64(o, "id") ?? 0)
            roles[id] = RoleRow(id, (jsonGetStr(o, "name") ?? ""))
        }
        for (o in objArr(r, "permissions")) {
            let id = (jsonGetInt64(o, "id") ?? 0)
            perms[id] = PermRow(id, (jsonGetStr(o, "code") ?? ""), (jsonGetStr(o, "name") ?? ""))
        }
        for (o in objArr(r, "role_permissions")) {
            let rid = (jsonGetInt64(o, "role_id") ?? 0)
            let pid = (jsonGetInt64(o, "permission_id") ?? 0)
            var list: ArrayList<Int64>
            match (rolePerms.get(rid)) {
                case Some(x) => list = x
                case None =>
                    list = ArrayList<Int64>()
                    rolePerms[rid] = list
            }
            list.add(pid)
        }
    }

    public func save(): Unit {
        let root = JsonObject()
        let ua = JsonArray()
        for ((_k, u) in users) {
            let o = JsonObject()
            o.put("id", JsonInt(u.id))
            o.put("username", JsonString(u.username))
            o.put("password_hash", JsonString(u.passwordHash))
            o.put("role_id", JsonInt(u.roleId))
            ua.add(o)
        }
        root.put("users", ua)
        let ra = JsonArray()
        for ((_k, r) in roles) {
            let o = JsonObject()
            o.put("id", JsonInt(r.id))
            o.put("name", JsonString(r.name))
            ra.add(o)
        }
        root.put("roles", ra)
        let pa = JsonArray()
        for ((_k, p) in perms) {
            let o = JsonObject()
            o.put("id", JsonInt(p.id))
            o.put("code", JsonString(p.code))
            o.put("name", JsonString(p.name))
            pa.add(o)
        }
        root.put("permissions", pa)
        let rpa = JsonArray()
        for ((rid, pids) in rolePerms) {
            for (pid in pids) {
                let o = JsonObject()
                o.put("role_id", JsonInt(rid))
                o.put("permission_id", JsonInt(pid))
                rpa.add(o)
            }
        }
        root.put("role_permissions", rpa)

        /* 原子落盘：先写 .tmp 再 rename，与 server/src/store.cj 同一口径 */
        let dir = parentDir(path)
        if (dir.size > 0 && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let tmp = path + ".tmp"
        File.writeTo(tmp, root.toString().toArray())
        rename(tmp, to: path, overwrite: true)
    }

    /* JSON 对象数组；缺失或类型不对时返回空（与 store.cj 的 arrOf 同义）。 */
    private func objArr(o: JsonObject, key: String): ArrayList<JsonObject> {
        let out = ArrayList<JsonObject>()
        match (jsonGetArray(o, key)) {
            case Some(a) =>
                var i: Int64 = 0
                let n = a.size()
                while (i < n) {
                    match (a.get(i)) {
                        case Some(v) =>
                            try {
                                out.add(v.asObject())
                            } catch (e: Exception) {
                                /* 逐条坏数据在这里跳过；load() 已在文件级做了"不静默降级" */
                                ()
                            }
                        case None => ()
                    }
                    i += 1
                }
            case None => ()
        }
        return out
    }

    private func parentDir(p: String): String {
        let b = p.toArray()
        var i = b.size - 1
        while (i >= 0) {
            if (b[i] == 47 || b[i] == 92) {
                return String.fromUtf8(b[0..i])
            }
            i -= 1
        }
        return ""
    }
}
