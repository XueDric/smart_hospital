package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.5–3.6 · 重置密码与注册配置 —— 4 个接口
 *
 * 重置密码是 v1 里「忘记密码」的**唯一出路**（不做短信/邮箱自助找回），
 * 所以它必须是可追溯的敏感操作：每次重置都写入 <数据目录>/audit.log。
 */

import stdx.encoding.json.*

/*
 * POST /api/v1/members/{id}/reset-password
 *
 * 权限：会长 / 副会长 / 部长 / 副部长，但**只能作用于档位低于自己的人** ——
 * 不可重置与自己**同权或更高权**的人（对自己而言就是同权，因此任何人都不能用
 * 本接口改自己的密码）。本人改密一律走 PUT /auth/password（需原密码）。
 *
 * L-4 口径澄清：api-design §3.8 汇总表与 v1-scope §3.4.3 曾把本接口写成"仅本人可用"，
 * 与 §3.5 / §6.1 的"会长重置成员密码"自相矛盾。已统一为**管理员操作**：
 *   · 本接口是"忘记密码"的唯一出路，它签发一次性临时密码，属于管理员救济动作；
 *   · 「本人可用」的语义由 PUT /auth/password 承担（要验原密码，更安全）；
 *   · 因此 scopeAllows 里那条 `case ResetPassword => return true` 的死代码已删除
 *     （角色维度从不给 member 放行 ResetPassword，那条分支永远到不了）。
 * 两处文档已同步，tests 里也钉了一条"成员对自己重置 -> 403"。
 *
 * N-7（2026-09-14）：上面那句"不能对自己用"原先只是**注释**，代码里并没有拦——
 * 「成员对自己 403」其实是角色维度挡的（member 档没有 ResetPassword），
 * 而会长与副会长的角色分支都是"直接放行"，所以他们重置自己会**成功**；
 * 本 handler 收尾又会 revokeOtherTokens(s, tgt.id, "") 把目标的全部令牌作废，
 * 于是表现为"响应 200、自己当场掉线"。
 *
 * 修法：在 perms.cj 的 checkAccess **动作语义层**加一条通用规则 ——
 * **不可重置与自己同权或更高权的人**（不在这里写 if，权限判定仍然只有一处）。
 * 这条规则一次覆盖三种情况：
 *   · 对自己同权 → 会长 / 副会长 / 部长都不能重置自己（N-7）；
 *   · 副会长对副会长同权 → 同权之间不能互相踢下线（原先没有这条约束）；
 *   · 会长档位最高，除自己外无人与之同权 → 会长仍能重置任何更低档的人。
 *
 * 连带口径：**本人改自己密码的通道不变**，仍是 PUT /auth/password（会长也一样）。
 * 唯一的边界是"彻底忘记原密码"——那条通道要验原密码，此时 v1 没有自助找回
 * （见 README「未决事项」#4），不在本次改动范围内。
 */
public func handleResetPassword(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")

    /*
     * 三段式（2026-09-15，容量基准的动作 2）。
     * 原先 `newPasswordRecord`（PBKDF2 10 万轮，~400 ms）在锁里跑 —— 一次重置把全服卡 0.4 s。
     * 现在：① 锁内先**判权限**（便宜，且能挡住"没权限的人骗 CPU"）；② 锁外算口令；
     * ③ 锁内复核权限与目标仍存在，再落库。
     */
    var temp = ""
    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.ResetPassword, targetOf(actor, tgt))
        temp = newTempPassword()
    } finally {
        s.lock.unlock()
    }

    /*
     * 锁外：PBKDF2（不占锁）。权限已经在上面判过，没权限的人走不到这里。
     *
     * 2026-09-17（P1）：这条同样要过 PBKDF2 并发闸门（N-21 原先只覆盖登录）。
     * 本接口没有幂等键、也没有节流，而每次调用 = 一次 10 万轮哈希 + 一次整库落盘：
     * 一个部长对本部门更低档成员反复 / 并发调用即可当杠杆用。
     */
    if (!pbkdf2Enter(s)) {
        throw apiErr("TOO_MANY_ATTEMPTS")
    }
    var rec: (String, String, Int64) = ("", "", 0)
    try {
        rec = newPasswordRecord(temp)
    } finally {
        pbkdf2Leave(s)
    }

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        /* 锁外那段时间里目标可能被移出/改角色 —— 复核权限（口径与第一次完全一致） */
        requireAccess(actor, Action.ResetPassword, targetOf(actor, tgt))
        tgt.pw_salt = rec[0]
        tgt.pw_hash = rec[1]
        tgt.pw_iter = rec[2]
        /* 改密后该成员的所有令牌失效——这是账号被盗时的自救手段 */
        revokeOtherTokens(s, tgt.id, "")
        storeSave(s)
        audit(s, actor.id, "reset-password", tgt.id, "临时密码已签发（其余令牌已失效）")
        let data = JsonObject()
        jPutStr(data, "temporary_password", temp)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/register-config —— 口令存明文，仅会长/副会长可读（v1-scope §5） */
public func handleRegisterConfigGet(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewRegisterCode, Target())
    s.lock.lock()
    try {
        sendOk(ctx, registerConfigView(s))
    } finally {
        s.lock.unlock()
    }
}

/*
 * PUT /api/v1/register-config/code —— 更换口令（**仅会长**）
 * 更换后旧口令立即失效；正在注册的人会失败，需在群里同步公告。
 */
public func handleRegisterConfigPut(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ChangeRegisterCode, Target())
    let body = reqObj(ctx)
    let v = V()
    /*
     * 2026-09-17：**先 trim 再计长**，并补字符集校验。
     *
     * 原问题有两个：① 直接用原值计长，而 `String.size` 是**字节数** —— 两个中文字（6 字节）
     * 就"满足 6 位"，熵远低于设计意图；② 注册侧（handleRegister 的 constantTimeEq 比对）
     * 过去不 trim，于是把口令设成"前后带空格"会让**全社团的注册都失败**，
     * 而这是肉眼看不见的差别。trim 的两处口径一致：存入侧 trim、比对侧也 trim
     * （见 h_auth.cj 的 handleRegister）。字符集沿用密码那条（可见 ASCII）：
     * 注册口令是要在群里念 / 贴出去的，全角字符和空白只会制造"看着一样、输入却不同"的故障。
     */
    let rawCode = v.need("code", reqStrOr(body, "code", ""), "请输入新的注册口令")
    let code = trimAsciiBlank(rawCode)
    if (rawCode.size > 0) {
        /* M-2：下限从 4 提到 6。注册口令是**全社团共用**、只需猜中一次就拿到账号的
         * 单一秘密，4 位字符（尤其纯数字）在线爆破是分钟级的事。6 位是成本与
         * 可传播性（要在群里发）之间的折中，同时配合 handleRegister 的失败限流。 */
        v.check("code", code.size >= 6, "注册口令至少 6 位（首尾空格不计）")
        v.check("code", code.size <= 32, "注册口令最多 32 位")
        v.check("code", passwordCharsetError(code).size == 0,
            "注册口令只能使用数字、英文和符号（不能有空格、中文或全角字符）")
    }
    v.done()

    let data = storeMutation(s, { =>
        s.register_code = code
        s.register_code_by = actor.id
        s.register_code_at = nowEpoch()
        audit(s, actor.id, "change-register-code", 0, "注册口令已更换")
        registerConfigView(s)
    })
    sendOk(ctx, data)
}

/* POST /api/v1/register-config/rotate —— 随机轮换（仅会长），用于"口令可能外泄" */
public func handleRegisterConfigRotate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ChangeRegisterCode, Target())
    let data = storeMutation(s, { =>
        s.register_code = newRegisterCode()
        s.register_code_by = actor.id
        s.register_code_at = nowEpoch()
        audit(s, actor.id, "rotate-register-code", 0, "注册口令已随机轮换")
        registerConfigView(s)
    })
    sendOk(ctx, data)
}
