package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 2 · 认证与注册（api-design.md Part 2，5 个接口中的 4 个 + 改密码）
 *
 * ⚠ 锁规则（重要）：
 *   requireMember / requireActive **内部会加 s.lock**，因此调用它们时
 *   绝不能已经持有 s.lock —— Mutex 不可重入，会死锁。
 *   handler 的统一形状是：**先认证（拿 Member），再单独加锁做修改**。
 */

import std.collection.*
import stdx.encoding.json.*

/* 登录限流参数（api-design §2.4）：15 分钟窗口，失败 5 次锁 15 分钟。 */
public let LOGIN_FAIL_WINDOW: Int64 = 900
public let LOGIN_FAIL_LIMIT: Int64 = 5
public let LOGIN_FAIL_LOCK: Int64 = 900

/*
 * 注册口令限流参数（N-6，2026-09-14 改）。
 * 窗口 15 分钟内错 10 次即锁该 IP；锁定时长**递增退避**：首次 5 分钟，
 * 同一 IP 每再触发一次翻倍，上限 1 小时。
 * 为什么不再固定 15 分钟：固定值让封锁成本恒定（每 15 分钟丢 10 个错口令就能一直锁着），
 * 递增退避让重复违规越来越贵。
 */
public let REG_FAIL_WINDOW: Int64 = 900
public let REG_FAIL_LIMIT: Int64 = 10
public let REG_FAIL_LOCK_BASE: Int64 = 300
public let REG_FAIL_LOCK_MAX: Int64 = 3600

/*
 * N-21：**同时**在跑的 PBKDF2 上限（登录与注册共用，注册那条见 handleRegister）。
 * N-16 之后未注册号码也要跑一次 10 万轮（实测 ~525 ms CPU），24 核下 ~46 并发即可打满整机
 * —— 而登录端点不需要认证。取 8 ≈ 最多占掉 1/3 的机器，剩下的留给正常请求；
 * 超出的直接 429（不排队）。
 *
 * 2026-09-18（口径收敛）：按 IP 的登录节流**已移除**，本闸门是应用层唯一的减载手段。
 * 决定与理由：抗 DDoS / 抗分布式滥用属于网络与流量层（云清洗、WAF、网关限速）；
 * 应用层只保留"与来源无关、只保护自己不被拖垮"的这一道。
 * 仍然保留的与来源有关的防护只有两处，且都不是抗 DDoS：
 *   · 按**手机号**的登录失败锁定（防猜口令，`LOGIN_FAIL_*`）；
 *   · 按**IP** 的注册口令节流（防暴力猜 6 位注册口令 —— 那是全社团共用的秘密，N-6）。
 */
public let MAX_PBKDF2_INFLIGHT: Int64 = 8

/*
 * 密码长度口径（D-6，2026-09-16 定稿）：**8–32 字节**。
 *
 * 三个口径曾各不相同：
 *   · UI 设计规格 P12 写「长度按字节计：6-32 位，中文一字 3 字节」
 *   · api-design §2.3 注 5 写「≥ 8 字节」
 *   · 实现是 `size >= 8`，**且没有上限** —— 超长密码随便进，与注册口令（6–32）不对称
 * 定稿取两者的并集下界与设计稿的上界：**下限 8（沿用既有口令强度口径）、上限 32（采纳设计稿）**。
 *
 * ⚠ 按**字节**计（Cangjie 的 `String.size` 就是字节数）。
 * 三个调用点（注册 / 本人改密 / init-admin）一律走 `passwordError`，
 * 避免多处各写一遍而漂移（L-10 的教训：同一上限写死在多处，改的时候必漏）。
 *
 * 2026-09-16 追加**字符集**约束（见下）：只允许数字、英文与符号。
 * 加了这条之后，"中文一字 3 字节"只影响**长度**怎么算；中文密码本身会被字符集挡掉。
 */
public let PASSWORD_MIN_BYTES: Int64 = 8
public let PASSWORD_MAX_BYTES: Int64 = 32

/*
 * 允许的密码字符：**数字、英文、符号**（2026-09-16 追加）。
 *
 * 判定 = 每个字节都是**可见 ASCII**（0x21–0x7E）。于是：
 *   · 中文（UTF-8 多字节）、全角字符一律被拒 —— 顺带避免输入法全角/半角造成
 *     "看起来一模一样、登录却失败"这类最难排查的问题
 *   · 空格（0x20）、TAB、换行也被排除：它们在表单里不可见，打错了用户看不出来
 *
 * 允许的符号就是这一区间里的可见 ASCII，例如 `._/\-!@#$%^&*()[]{}<>?~` 等。
 */
public func isAllowedPasswordChar(b: UInt8): Bool {
    /* 33 = '!'，126 = '~'；只比字面量，不走 stdx（strx.cj 开头那条纪律） */
    return b >= 33 && b <= 126
}

/* 字符集校验：返回空串表示合法，否则返回字段级提示。 */
public func passwordCharsetError(pw: String): String {
    for (b in pw.toArray()) {
        if (!isAllowedPasswordChar(b)) {
            return "密码只能使用数字、英文和符号（._/\\ 等），不能有空格、中文或全角字符"
        }
    }
    return ""
}

/*
 * 密码校验的**唯一入口**：长度（8–32 字节）+ 字符集（数字/英文/符号）。
 * 返回空串表示合法，否则返回给用户看的字段级提示。
 * 重置密码签发的临时密码是 8 位 ASCII（ids.cj 的 `randCode(8)`），落在区间内。
 */
public func passwordError(pw: String): String {
    let lenErr = passwordLenError(pw)
    if (lenErr.size > 0) {
        return lenErr
    }
    return passwordCharsetError(pw)
}

/* 长度校验（被 passwordError 调用；单独公开是为了单测能分别钉住上下界）。 */
public func passwordLenError(pw: String): String {
    if (pw.size < PASSWORD_MIN_BYTES) {
        return "密码至少 ${PASSWORD_MIN_BYTES} 位（按字节计）"
    }
    if (pw.size > PASSWORD_MAX_BYTES) {
        return "密码最多 ${PASSWORD_MAX_BYTES} 位（按字节计）"
    }
    return ""
}

/*
 * 登录失败表清理（P1 M-3）。
 * 原先只增不减：每个被试过的手机号都留一条记录，锁定过期也不回收。
 * 这里把"窗口已过且锁定已解除"的记录删掉；平时（表很小）直接返回，不做无谓遍历。
 */
func pruneLoginFail(s: Store, now: Int64): Unit {
    if (s.login_fail.size <= 500) {
        return
    }
    let doomed = ArrayList<String>()
    for ((k, r) in s.login_fail) {
        if (r.locked_until <= now && now - r.first_at > LOGIN_FAIL_WINDOW) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        s.login_fail.remove(k)
    }
}

/* 递增退避：level = 该 IP 已被锁过的次数。300 → 600 → 1200 → 2400 → 上限 3600。 */
func regLockSeconds(level: Int64): Int64 {
    var v = REG_FAIL_LOCK_BASE
    var i: Int64 = 0
    while (i < level && v < REG_FAIL_LOCK_MAX) {
        v = v * 2
        i += 1
    }
    if (v > REG_FAIL_LOCK_MAX) {
        v = REG_FAIL_LOCK_MAX
    }
    return v
}

/* 该表里这个 IP 此刻是否处于锁定期（N-6 注册口令节流；登录的按 IP 节流已于 2026-09-18 移除）。 */
func ipLocked(tbl: HashMap<String, RegFail>, ip: String, now: Int64): Bool {
    match (tbl.get(ip)) {
        case Some(st) => return st.locked_until > now
        case None => return false
    }
}

func regLocked(s: Store, ip: String, now: Int64): Bool {
    return ipLocked(s.reg_fail, ip, now)
}

/* 节流表清理（与 pruneLoginFail 同构）：超过 500 条时回收"窗口已过且已解锁"的 IP。 */
func pruneIpFail(tbl: HashMap<String, RegFail>, now: Int64): Unit {
    if (tbl.size <= 500) {
        return
    }
    let doomed = ArrayList<String>()
    for ((k, st) in tbl) {
        if (st.locked_until <= now && now - st.first_at > REG_FAIL_WINDOW) {
            doomed.add(k)
        }
    }
    for (k in doomed) {
        tbl.remove(k)
    }
}

func pruneRegFail(s: Store, now: Int64): Unit {
    pruneIpFail(s.reg_fail, now)
}

/* 失败计数 + 递增退避（落在指定表里）。 */
func ipFailBump(tbl: HashMap<String, RegFail>, ip: String): Unit {
    let now = nowEpoch()
    let st = tbl.get(ip) ?? RegFail()
    if (st.first_at == 0 || now - st.first_at > REG_FAIL_WINDOW) {
        st.first_at = now
        st.count = 0
    }
    st.count += 1
    if (st.count >= REG_FAIL_LIMIT) {
        st.locked_until = now + regLockSeconds(st.lock_level)
        st.lock_level += 1
        st.count = 0
        st.first_at = now
    }
    tbl[ip] = st
    pruneIpFail(tbl, now)
}

func regFailBump(s: Store, ip: String): Unit {
    ipFailBump(s.reg_fail, ip)
}

/*
 * PBKDF2 并发闸门（N-21）：进入/离开。见 Store.pbkdf2_lock / pbkdf2_inflight 的注释。
 * 选"满了就拒"而不是"排队"：登录是可重试的低频操作，快速失败比堆积更好。
 */
func pbkdf2Enter(s: Store): Bool {
    s.pbkdf2_lock.lock()
    try {
        if (s.pbkdf2_inflight >= MAX_PBKDF2_INFLIGHT) {
            return false
        }
        s.pbkdf2_inflight += 1
        return true
    } finally {
        s.pbkdf2_lock.unlock()
    }
}

func pbkdf2Leave(s: Store): Unit {
    s.pbkdf2_lock.lock()
    try {
        if (s.pbkdf2_inflight > 0) {
            s.pbkdf2_inflight -= 1
        }
    } finally {
        s.pbkdf2_lock.unlock()
    }
}

/*
 * 注册口令失败计数（P1 M-2；N-6 从全局计数改为**按 IP**）。
 * 窗口内累计到上限就锁定**该 IP**，锁定期间该 IP 的注册一律 429——
 * 其它 IP 完全不受影响，这是与旧全局锁最关键的区别。
 * 与 login_fail 同理不落盘：失败路径上写整库等于给攻击者一个放大杠杆。
 *
 * 实现已上移到 `ipFailBump`（N-21 让登录也复用同一套），这里只留说明。
 */

/*
 * 登录/注册成功的统一响应体。
 *
 * `deptHintId`（D-16，2026-09-16）：注册时**实际采纳**的部门预填。
 * 为什么要在响应里回显：预填的优先级有两条来源（招募链接 token / 客户端自报 dept_id），
 * 若 token 恰好已停用，客户端自报的那个会**静默失效** —— 回显让"到底采纳了什么"
 * 是可观察的，而不是让调用方自己猜（本项目一贯纪律：不静默忽略）。
 * 登录不采纳预填，恒为 0 → `dept_hint: null`。
 */
func respondLogin(ctx: Context, s: Store, m: Member, token: String, expiresAt: Int64, created: Bool,
                  deptHintId: Int64): Unit {
    let data = JsonObject()
    jPutStr(data, "token", token)
    jPutStr(data, "expires_at", isoLocal(expiresAt))
    jPutObj(data, "member", memberBrief(s, m))
    jPutObj(data, "permissions", permissionsOf(m))
    if (deptHintId > 0) {
        jPutObj(data, "dept_hint", deptBriefObj(s, deptHintId))
    } else {
        jPutNull(data, "dept_hint")
    }
    if (created) {
        sendCreated(ctx, data)
    } else {
        sendOk(ctx, data)
    }
}

/*
 * POST /api/v1/auth/register
 * 注册即登录，但账号是 pending、权限全 false，客户端应跳「等待管理员分配」页。
 * 请求体**不接受 role**——任何角色都必须由会长授予（api-design §2.3 注 4）。
 *
 * D-16（2026-09-16）：部门预填有**两条来源**，优先级如下：
 *   ① `invite_token`（招募链接）→ 服务端自己解析，**优先**
 *   ② `dept_id`（客户端自报）  → 仅在 token 缺失/无效/已停用时才采纳
 * 链接仍只是"便利"：它不免除注册口令，也不赋予任何角色（api-design §3.7）。
 * 采纳结果在响应 `data.dept_hint` 里回显，避免"客户端以为预填生效了"。
 */
public func handleRegister(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    /* 2026-09-17：提交的口令先 trim —— 与 PUT /register-config 的存入侧口径一致。
     * 用户从群里复制口令时带首尾空白是常态，不该因此注册失败。 */
    let rc = trimAsciiBlank(v.need("register_code", reqStrOr(body, "register_code", ""), "请输入社团注册口令"))
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let name = v.need("name", reqStrOr(body, "name", ""), "请输入姓名")
    /* 2026-09-17：姓名长度上限（见 limits.cj） */
    lenCheck(v, "name", "姓名", name, MAX_NAME_BYTES)
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    if (phone.size > 0) {
        v.check("phone", isPhone(phone), "手机号格式不正确")
    }
    if (pw.size > 0) {
        /* D-6：8–32 字节 + 只用数字/英文/符号（原先只校验下限，超长与非 ASCII 一律放行） */
        let pwErr = passwordError(pw)
        v.check("password", pwErr.size == 0, pwErr)
    }
    v.done()

    let bodyDept = reqIntOr(body, "dept_id", 0)
    let inviteToken = reqStrOr(body, "invite_token", "").trimAscii()

    /* ---------- ① 锁内（极短）：口令存在性 + 按 IP 限流 + 解析招募链接；只把标量拷出来 ---------- */
    var expectedCode = ""
    var invitedDept: Int64 = 0
    s.lock.lock()
    try {
        if (s.register_code.size == 0) {
            throw apiErrMsg("REGISTER_CODE_INVALID", "社团尚未设置注册口令，请联系会长")
        }
        /* 限流（P1 M-2 / N-6）：注册口令是**全社团共用的一个短串**，必须限制尝试次数。
         *
         * 2026-09-14 从"全局计数"改成**按客户端 IP**：
         *   · 旧口径说"轻舟没有暴露可信客户端 IP"——这句是错的。轻舟通过
         *     ctx.http.request.remoteAddr 给出 **TCP 对端地址**，那是传输层事实，
         *     客户端伪造不了（可伪造的是 X-Forwarded-For 头，而本项目直连、不读它）；
         *     h_ops.cj 的 peerOf / clientIpOf 就是取它。
         *   · 旧全局锁的真实代价：攻击者每 15 分钟丢 10 个错口令就能把**所有人**
         *     挡在注册门外。改成按 IP 后，被锁的只有攻击者自己那个地址。
         *   · 锁定改为**递增退避**（见 regLockSeconds），重复违规成本上升。
         *
         * 已知局限（写清楚，别高估）：NAT / 校园网出口下整个社团可能共用一个公网 IP，
         * 那时按 IP 会近似退化成全局锁；拿不到对端地址时 key 为空串，同样退化为全局。
         * 两种情况都比"无条件全局锁"更窄，且锁只影响注册、不影响登录与其它接口。 */
        let ip = clientIpOf(ctx)
        if (regLocked(s, ip, nowEpoch())) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        /*
         * 2026-09-17：**存入侧也 trim 一次**（不是只 trim 提交值）。
         *
         * 本次改动把提交侧与存入侧都改成 trim 口径，但库里可能已经有**改动前**设下的
         * 首尾带空白的口令（旧代码允许，GET 会原样回显）。如果只 trim 提交值，
         * 那些社团会陷入"口令明明是对的、注册却永远失败"的死局，而错误码仍是
         * REGISTER_CODE_INVALID，看不出是空白问题。这里把存量值也按同一口径归一，
         * 新旧数据都能对上（真正的口令本体不变）。
         */
        expectedCode = trimAsciiBlank(s.register_code)
        /* D-16：链接由服务端解析（停用/不存在 → 0，自动退回客户端自报的 dept_id） */
        invitedDept = resolveInviteDept(s, inviteToken)
    } finally {
        s.lock.unlock()
    }

    /* ---------- ② 锁外：口令比对 + PBKDF2（动作 2：这段 CPU 不占锁） ---------- */
    if (!constantTimeEq(rc, expectedCode)) {
        /* 失败记账要单独加一次锁（表在内存，不落盘） */
        s.lock.lock()
        try {
            regFailBump(s, clientIpOf(ctx))
        } finally {
            s.lock.unlock()
        }
        throw apiErr("REGISTER_CODE_INVALID")
    }
    /*
     * 2026-09-17（P1）：**注册这条 PBKDF2 也要过并发闸门**。
     *
     * N-21 的闸门原先只挂在登录上，而注册同样是**未认证**端点、且更贵：
     * 成功路径要算一次 10 万轮哈希（本机实测 ~0.6 s CPU）。
     * 知道注册口令的人（口令是全社团共用、要在群里念出来的）并发刷注册，
     * 就能把整机 CPU 打满 —— 闸门上限是 8，而 24 核下约 46 并发即饱和
     * （见 MAX_PBKDF2_INFLIGHT 的注释与 docs/code-review.md 的 N-21 测算）。
     */
    if (!pbkdf2Enter(s)) {
        throw apiErr("TOO_MANY_ATTEMPTS")
    }
    var rec: (String, String, Int64) = ("", "", 0)
    try {
        rec = newPasswordRecord(pw)
    } finally {
        pbkdf2Leave(s)
    }

    /* ---------- ③ 锁内：清限流 + 复核手机号未被抢注 + 建账号 + 发令牌 ---------- */
    s.lock.lock()
    try {
        s.reg_fail.remove(clientIpOf(ctx))
        /* 锁外那段时间里，同一手机号可能已被别人注册成功 —— 复核一次 */
        if (memberByPhone(s, phone).isSome()) {
            throw apiErrFields("ALREADY_EXISTS", "该手机号已注册", oneField("phone", "该手机号已注册"))
        }
        let m = Member()
        m.id = s.next_member
        s.next_member += 1
        m.name = name
        m.phone = phone
        m.pw_salt = rec[0]
        m.pw_hash = rec[1]
        m.pw_iter = rec[2]
        m.status = "pending"
        m.role = ""
        m.dept_id = 0
        /*
         * D-16 的优先级落地：链接解析出来的部门**优先于**客户端自报的 dept_id。
         * 两条都不可用时预填为空（不阻断注册 —— 链接只是便利，口令才是准入）。
         */
        var hintTaken: Int64 = 0
        if (invitedDept > 0 && s.departments.contains(invitedDept)) {
            hintTaken = invitedDept
        } else if (bodyDept > 0 && s.departments.contains(bodyDept)) {
            hintTaken = bodyDept
        }
        if (hintTaken > 0) {
            m.dept_hint = hintTaken
        }
        m.joined_at = nowEpoch()
        s.members[m.id] = m

        let issued = issueToken(s, m.id)
        storeSave(s)
        respondLogin(ctx, s, m, issued[0], issued[1], true, hintTaken)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/auth/login
 * 手机号不存在与密码错误返回同一个错误码，不泄露某号码是否注册过。
 * 限流：同一手机号 15 分钟内失败 5 次 → 锁定 15 分钟（api-design §2.4）。
 *
 * P1 M-3 的两处修正：
 *   1. 形态不对的手机号直接 400，**不写进 login_fail**。否则攻击者用随机串刷接口，
 *      就能让这张表无限膨胀（磁盘与内存一起涨）。
 *   2. 失败不再调用 storeSave。原先每失败一次就整库落盘一次 —— 一个 401 打出来
 *      18 MB 写盘，本身就是会被利用的放大杠杆。login_fail 是**短时效限流状态**，
 *      只留在内存：重启后清零可以接受（攻击者无法让服务重启），
 *      但绝不能每次都拿它去写整库。
 */
/*
 * 三阶段加锁（2026-09-15，容量基准的动作 2）。
 *
 * 为什么改：PBKDF2 一次 10 万轮，实测 **~400 ms**，而它原先是在**全局锁里**跑的
 * （`s.lock.lock()` → `verifyPw` → `storeSave` → 响应）。后果是一次登录把整个服务
 * 卡住 0.4 s，登录只能串行 ≈ 2 次/秒 —— 千人社团招新期会明显排队。
 * 这不是存储的锅，是"锁里做 CPU 密集活"。
 *
 * 现在拆成三段：
 *   ① 锁内（极短）：限流判定 + 把该手机号的口令材料**拷成标量**带出锁
 *   ② 锁外：`verifyPw`（最贵的 CPU，不再占锁）
 *   ③ 锁内（短）：记失败账 / 复核 `pw_hash` 未被并发改过 / 签令牌 / 落盘
 *
 * ⚠ 纪律：**不能把 `Member` 引用带出锁外使用**（会被并发修改）。这里只拷
 * `pw_salt / pw_hash / pw_iter` 与 `id` 四个标量；第 ③ 段重新按 id 取成员并复核。
 */
public func handleLogin(ctx: Context, s: Store): Unit {
    let body = reqObj(ctx)
    let v = V()
    let phone = v.need("phone", reqStrOr(body, "phone", ""), "请输入手机号")
    let pw = v.need("password", reqStrOr(body, "password", ""), "请输入密码")
    if (phone.size > 0) {
        v.check("phone", isPhone(phone), "手机号格式不正确")
    }
    v.done()

    /* ---------- ① 锁内：限流判定 + 取口令材料 ---------- */
    var credSalt = ""
    var credHash = ""
    var credIter: Int64 = 0
    var memberId: Int64 = 0
    var found = false
    s.lock.lock()
    try {
        let now = nowEpoch()
        /*
         * 2026-09-18：这里原先还有一道**按 IP** 的登录节流（N-21）。
         * 已按"应用层不做抗 DDoS"的口径移除 —— 它挡不住分布式，且在 NAT / 校园网
         * 出口下会把整个社团一起锁在外面。现在只保留按**手机号**的失败锁定（防猜口令），
         * 以及锁外那道与来源无关的 PBKDF2 并发闸门（防整机被拖垮）。
         */
        let lf = s.login_fail.get(phone) ?? LoginFail()
        if (lf.locked_until > now) {
            throw apiErr("TOO_MANY_ATTEMPTS")
        }
        match (memberByPhone(s, phone)) {
            case Some(m) =>
                credSalt = m.pw_salt
                credHash = m.pw_hash
                credIter = m.pw_iter
                memberId = m.id
                found = true
            case None => ()
        }
    } finally {
        s.lock.unlock()
    }

    /* ---------- ② 锁外：口令校验（~400 ms CPU，不占锁） ---------- */
    /*
     * N-16：号码不存在也照样跑一次**等价成本**的 PBKDF2（假材料，结果丢弃）。
     * 否则"号码不存在"比"口令错误"快一个量级，登录接口就能被用来枚举手机号。
     * 材料由纯函数 loginCreds 给出（见 auth.cj），它同时是这条修复的回归闸门。
     */
    if (!pbkdf2Enter(s)) {
        /* N-21：同时在算的 PBKDF2 已达上限 —— 直接拒，**不排队**（见 MAX_PBKDF2_INFLIGHT） */
        throw apiErr("TOO_MANY_ATTEMPTS")
    }
    var ok = false
    try {
        let creds = loginCreds(found, credSalt, credHash, credIter)
        ok = verifyPw(pw, creds[0], creds[1], creds[2]) && found
    } finally {
        pbkdf2Leave(s)
    }

    /* ---------- ③ 锁内：记账 / 复核 / 签发 ---------- */
    s.lock.lock()
    try {
        if (!ok) {
            /* 手机号不存在与口令错误走同一条路：不泄露某个号码是否注册过 */
            let now = nowEpoch()
            var lf = s.login_fail.get(phone) ?? LoginFail()
            if (now - lf.first_at > LOGIN_FAIL_WINDOW) {
                lf.count = 0
                lf.first_at = now
            }
            lf.count += 1
            if (lf.count >= LOGIN_FAIL_LIMIT) {
                lf.locked_until = now + LOGIN_FAIL_LOCK
                lf.count = 0
                lf.first_at = now
            }
            s.login_fail[phone] = lf
            pruneLoginFail(s, now)
            /* 故意不落盘：见上方注释第 2 条 */
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }

        /* 锁外那段时间里账号可能被改密 / 移出 / 删除 —— 复核后才签发 */
        let m = match (s.members.get(memberId)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        if (m.pw_hash != credHash) {
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        if (m.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }
        s.login_fail.remove(phone)
        /*
         * 成功即清掉该**手机号**的失败计数（"猜口令"这条轴的正常语义）。
         * 2026-09-18 之前这里还特意不动那张按 IP 的表，避免"用自己已知的账号登录成功
         * 就把 IP 计数清零"；那张表已随"应用层不做抗 DDoS"的口径一起移除。
         */
        let issued = issueToken(s, m.id)
        storeSave(s)
        /* 登录不采纳部门预填 → dept_hint 恒为 null */
        respondLogin(ctx, s, m, issued[0], issued[1], false, 0)
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/auth/logout —— 服务端删映射，旧令牌立即失效。 */
public func handleLogout(ctx: Context, s: Store): Unit {
    let tok = match (bearerToken(ctx)) {
        case Some(t) => t
        case None => throw apiErr("AUTH_REQUIRED")
    }
    storeMutation(s, { =>
        s.tokens.remove(tok)
    })
    sendOk(ctx, JsonObject())
}

/*
 * GET /api/v1/auth/me
 * 客户端启动时第一个调用的接口：既校验令牌，又拿权限摘要。
 * pending 账号也能正常调用（返回 view_scope = none），不能当成错误。
 */
public func handleMe(ctx: Context, s: Store): Unit {
    let m = requireMember(ctx, s)
    let data = JsonObject()
    /*
     * 2026-09-17（P1）：视图构造**必须在锁内**。
     *
     * `memberSelf` → `memberBrief` → `deptBriefObj` 要读 `s.departments`（HashMap），
     * 而原先这里不持锁 —— "锁外读 Store"与并发写是数据竞争，与
     * docs/capacity-baseline.md §4.4 定的纪律（"HashMap 非线程安全，锁外读与写并发
     * 是数据竞争"，这也正是当初不改那 26 个 storeSave 调用点的理由）自相矛盾。
     * 本接口是客户端启动时第一个调的（频率最高），所以先把它补上。
     * `sendOk` 仍留在锁外：它只把已经建好的对象序列化，不再碰 Store。
     */
    s.lock.lock()
    try {
        let cur = match (s.members.get(m.id)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_REQUIRED")
        }
        jPutObj(data, "member", memberSelf(s, cur))
        jPutObj(data, "permissions", permissionsOf(cur))
    } finally {
        s.lock.unlock()
    }
    sendOk(ctx, data)
}

/* PUT /api/v1/auth/password —— 本人改密，改完其他令牌全部失效。 */
public func handleChangePassword(ctx: Context, s: Store): Unit {
    let m = requireMember(ctx, s)
    let tok = bearerToken(ctx) ?? ""
    let body = reqObj(ctx)
    let v = V()
    let oldPw = v.need("old_password", reqStrOr(body, "old_password", ""), "请输入原密码")
    let newPw = v.need("new_password", reqStrOr(body, "new_password", ""), "请输入新密码")
    if (newPw.size > 0) {
        /* D-6：与注册同一口径（8–32 字节 + 数字/英文/符号），走同一个纯函数 */
        let pwErr = passwordError(newPw)
        v.check("new_password", pwErr.size == 0, pwErr)
    }
    v.done()

    /*
     * 三段式（动作 2）：验旧口令与算新口令**都是** PBKDF2（两次约 800 ms），
     * 原先全在锁里 → 一次改密把全服卡 0.8 s。现在只把标量拷出锁。
     */
    var curSalt = ""
    var curHash = ""
    var curIter: Int64 = 0
    s.lock.lock()
    try {
        let cur = match (s.members.get(m.id)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_REQUIRED")
        }
        curSalt = cur.pw_salt
        curHash = cur.pw_hash
        curIter = cur.pw_iter
    } finally {
        s.lock.unlock()
    }

    /*
     * 锁外：**先验旧口令**，验过了才算新口令 —— 失败时只花一次 PBKDF2，不给放大杠杆。
     *
     * 2026-09-17（P1）：本路径的两次 PBKDF2 也要过并发闸门（N-21 原先只覆盖登录）。
     * 这里比登录更容易被滥用：requireMember 只要求**持有令牌**，连 pending
     * （刚注册、还没被分配）的账号都能打，而"旧口令填错"就足以烧掉一次 10 万轮哈希。
     * 闸门按"一次改密 = 一个槽位"计（验旧 + 算新在同一槽位内完成）。
     */
    if (!pbkdf2Enter(s)) {
        throw apiErr("TOO_MANY_ATTEMPTS")
    }
    var oldOk = false
    var rec: (String, String, Int64) = ("", "", 0)
    try {
        oldOk = verifyPw(oldPw, curSalt, curHash, curIter)
        if (oldOk) {
            rec = newPasswordRecord(newPw)
        }
    } finally {
        pbkdf2Leave(s)
    }
    if (!oldOk) {
        throw apiErr("AUTH_BAD_CREDENTIALS")
    }

    s.lock.lock()
    try {
        let cur = match (s.members.get(m.id)) {
            case Some(x) => x
            case None => throw apiErr("AUTH_REQUIRED")
        }
        /* 锁外那段时间里口令可能已被改过（例如管理员重置）—— 复核，别用旧凭据覆盖新口令 */
        if (cur.pw_hash != curHash) {
            throw apiErr("AUTH_BAD_CREDENTIALS")
        }
        cur.pw_salt = rec[0]
        cur.pw_hash = rec[1]
        cur.pw_iter = rec[2]
        revokeOtherTokens(s, m.id, tok)
        storeSave(s)
    } finally {
        s.lock.unlock()
    }
    sendOk(ctx, JsonObject())
}
