/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== acceptance_ai.cj —— P3 AI 能力中心的验收测试（需要库）==============
 *
 * ★★ 本文件的**第一要务**是守住 brief §5.3 点名的那条安全红线：
 *    「改成 DB 驱动时，**把密钥写进库是倒退**」
 *
 *   所以 AC-P3-1 不是"功能能用"，而是"**密钥进不去库**"。
 *    功能坏了看得见；密钥泄露看不见，而且事后无法收回。
 */

package qingzhou

import std.collection.*

/* 清 AI 配置表（测试用）。 */
func hResetAiSettings(db: DbBackend): Unit {
    db.exec("DELETE FROM ai_setting", Array<DbValue>())
}

/*
 * AC-P3-1 ★★ 「密钥不落库」是**机制性**保证，不是靠自觉。
 *
 * 断言分三层（一层比一层硬）：
 *   ① 合法引用能存、非法形状被拒（含"看起来像密钥"的值）；
 *   ② 被拒的值**真的没有**进库（不是"拒了但已经写了一半"）；
 *   ③ ★★ 直接扫全表：**任何**一行的值都不是长随机串（"像密钥"的形状）。
 *      这一层是**兜底**：即使将来有人加了别的写库路径绕过 put()，
 *      它也能抓到"库里出现了一个像密钥的东西"。
 */
public func acP3_1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-1 ★★ 密钥不落库（机制性保证）===")
    runner.section("AC-P3-1", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let repo = AiSettingsRepo(db)

        // ① 合法的两种形状
        let okEnv = repo.put(SET_AI_KEY_REF, "env:SMART_HOSPITAL_AI_KEY", now)
        runner.check("① 合法引用 env:NAME 被接受", okEnv.ok)
        let okFile = repo.put(SET_AI_KEY_REF, "file:/etc/smart-hospital/ai.key", now)
        runner.check("① 合法引用 file:/path 被接受", okFile.ok)

        // ② 非法形状必须被拒（含"前缀合法但本体是密钥"的绕过尝试）
        let bads: Array<(String, String)> = [
            ("sk-abcdefghijklmnopqrstuvwxyz012345", "裸密钥（无前缀）"),
            ("env:sk-abcdefghijklmnopqrstuvwxyz", "**前缀合法但本体是密钥**（绕过尝试）"),
            ("env:", "env: 后面为空"),
            ("env:123STARTS_WITH_DIGIT", "环境变量名以数字开头"),
            ("env:HAS-DASH", "环境变量名含非法字符 -"),
            ("file:", "file: 后面为空"),
            ("file:not-a-path", "file: 后面不是路径"),
            ("https://api.example.com/v1?key=sk-xxx", "直接给了 URL（含密钥）"),
            ("  ", "全空白")
        ]
        var allRejected = true
        for ((v, why) in bads) {
            let r = repo.put(SET_AI_KEY_REF, v, now)
            // "  " 是空值 = 不配置，按设计是允许的（会落到 enabled=false）
            let isBlank = v.trimAscii().size == 0
            if (isBlank) {
                if (!r.ok) {
                    allRejected = false
                    println("        空白值应被接受（= 不配置），却被拒：${why}")
                }
            } else if (r.ok) {
                allRejected = false
                println("        ★★ 未拒绝：${why}  -> 「${v}」")
            }
        }
        runner.check("★★ ② 所有非法形状（含绕过尝试）都被拒", allRejected)

        // ★★ ③ 被拒的值真的没有进库
        let cur = repo.get(SET_AI_KEY_REF, now)
        var leaked = false
        for ((v, _why) in bads) {
            if (v.trimAscii().size > 0 && cur == v) {
                leaked = true
            }
        }
        runner.check("★★ ③ 被拒的值**没有**进入库（当前值仍是合法引用）", !leaked)
        runner.check("③ 且当前值确实是合法引用形状（实得 '${cur}'）", validateKeyRef(cur).size == 0)

        // ★★ ④ 全表兜底扫描：没有任何一行的值是"像密钥"的长随机串
        let rs = db.query("SELECT k, v FROM ai_setting", Array<DbValue>())
        var suspicious = 0
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let v = rs.getString(i, 1)
            // "像密钥"：长度 >= 32 且全是 base64/hex 风格字符（无空格、无冒号、无斜杠）
            if (v.size >= 32 && looksLikeSecret(v)) {
                suspicious = suspicious + 1
                println("        ★★ 可疑值：${rs.getString(i, 0)} = 「${v}」")
            }
            i = i + 1
        }
        runner.check("★★ ④ 全表扫描：没有任何一行像密钥（可疑 ${suspicious} 行）", suspicious == 0)

        // ⑤ 回显视图：secret 项不得输出值、连引用名/路径都不输出
        let view = aiSettingsJson(repo, now).toString()
        runner.check("⑤ 回显里**不含** 密钥引用的变量名", !view.contains("SMART_HOSPITAL_AI_KEY"))
        runner.check("⑤ 回显里**不含** 密钥引用的路径", !view.contains("/etc/smart-hospital/ai.key"))
        runner.check("⑤ 回显里含 ref_kind（只给「是 env 还是 file」）", view.contains("ref_kind"))
        runner.check("⑤ 回显里 secret 项标记为 true", view.contains("\"secret\":true"))
    })
}

/*
 * "像不像密钥"的启发式：长度 >= 32 且**不含**任何"引用语法"字符
 * （空格 / 冒号 / 斜杠 / 反斜杠）。
 *
 * ⚠ 这只是**兜底**用的启发式，不是"密钥检测器" —— 它可能误报（一个 32 位的
 *   base64 值恰好不是密钥）也可能漏报（短密钥、含斜杠的令牌）。
 *   真正的保证是 `validateKeyRef()`（形状白名单）；这一层只防"绕过 put() 的路径"。
 */
func looksLikeSecret(v: String): Bool {
    for (ch in v.toArray()) {
        let c = Int64(ch)
        if (c == 0x20 || c == 0x3A || c == 0x2F || c == 0x5C || c == 0x2E || c == 0x2D) {
            return false      // 含空格/冒号/斜杠/点/短横 ⇒ 像路径或引用，不像裸密钥
        }
    }
    return true
}

/*
 * AC-P3-2 ★★ 「改配置零重启」—— 写库后下一次读必须拿到新值。
 *
 * 这是 P3 的**功能目标本身**（brief §2.2 创新点①）。断言要覆盖"缓存真的失效了"，
 * 而不是"恰好没缓存"：所以先在同一个 repo 实例上**读一次**（把值灌进缓存），
 * 再写、再读 —— 如果 invalidate() 没生效，第二次读会拿到旧的缓存值。
 */
public func acP3_2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-2 ★★ 改配置零重启（写后即生效）===")
    runner.section("AC-P3-2", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let repo = AiSettingsRepo(db)

        // ① 先读一次 → 灌满缓存
        let v1 = repo.get(SET_AI_ENDPOINT, now)
        runner.check("① 未配置时读到默认值（空）", v1.size == 0)
        // ② 写 → 同一个 repo 实例再读（★ 缓存必须已失效）
        let w = repo.put(SET_AI_ENDPOINT, "https://api.example.com/v1/chat/completions", now)
        runner.check("② 写入成功", w.ok)
        let v2 = repo.get(SET_AI_ENDPOINT, now)
        runner.check("★★ ② 同一实例立刻读到新值（缓存已失效，无需重启）",
                     v2 == "https://api.example.com/v1/chat/completions")
        // ③ 改写 → 立刻生效
        let _w2 = repo.put(SET_AI_ENDPOINT, "https://api2.example.com/v1/chat/completions", now)
        // ⚠ 不跨行写 `==`（仓颉报 possibly confusing line terminator）—— 拆成局部变量
        let afterRewrite = repo.get(SET_AI_ENDPOINT, now)
        runner.check("★★ ③ 改写后立刻生效", afterRewrite == "https://api2.example.com/v1/chat/completions")
        // ④ 删 → 回到默认值
        let _r = repo.remove(SET_AI_ENDPOINT, now)
        runner.check("④ 删除后回到默认值（空）", repo.get(SET_AI_ENDPOINT, now).size == 0)

        // ⑤ ★ 另一个实例也看得到（因为以库为准，不是进程内私货）
        let other = AiSettingsRepo(db)
        let _w3 = repo.put(SET_AI_MODEL, "deepseek-chat", now)
        runner.check("★ ⑤ 另一个仓储实例读到同一个值（配置是**库**的状态，不是实例的）",
                     other.get(SET_AI_MODEL, now) == "deepseek-chat")

        // ⑥ 未登记的 key 必须被拒（否则 KV 表会变垃圾场）
        let bad = repo.put("ai.some_random_key", "x", now)
        runner.check("⑥ 未登记的配置项被拒", !bad.ok)
        runner.check("⑥ 拒绝原因非空（给运维看）", bad.rejected.size > 0)
        let cnt = db.query("SELECT COUNT(*) FROM ai_setting WHERE k = 'ai.some_random_key'",
                           Array<DbValue>())
        runner.check("⑥ 未登记的 key 确实没进库",
                     cnt.rowCount() > 0 && cnt.getInt(0, 0) == 0)
    })
}

/*
 * AC-P3-3 配置校验：不自洽的配置必须**明确不可用**，而不是"看起来配好了"。
 *
 * ⚠ 边界值照抄基线 `aiValidate`（每条背后都有实测踩出来的理由）——
 *   见 `aiRuntimeValidate` 的注释。这里盯的是"**总开关与配置自洽性都参与判定**"：
 *   配置全对但总开关为 0 ⇒ 仍然不可用，且理由要说清是**开关**不是配置错
 *   （否则运维会去改配置，而问题在开关）。
 */
public func acP3_3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-3 配置校验与总开关 ===")
    runner.section("AC-P3-3", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let repo = AiSettingsRepo(db)

        // ① 全空 ⇒ 不可用，理由提到 endpoint
        let o1 = repo.options(now)
        runner.check("① 未配置时 enabled=false", !o1.enabled)
        runner.check("① 理由非空且提到 endpoint", o1.disabledReason.contains(SET_AI_ENDPOINT))

        // ② 配齐但**总开关为 0** ⇒ 不可用，且理由说清是开关
        let _a = repo.put(SET_AI_ENDPOINT, "https://api.example.com/v1", now)
        let _b = repo.put(SET_AI_MODEL, "m", now)
        let _c = repo.put(SET_AI_KEY_REF, "env:AIKEY", now)
        let o2 = repo.options(now)
        runner.check("② 配置齐全但总开关 0 ⇒ enabled=false", !o2.enabled)
        runner.check("★ ② 理由指明是**开关**（否则运维会去改配置，而问题在开关）",
                     o2.disabledReason.contains(SET_AI_ENABLED))

        // ③ 打开总开关 ⇒ 可用
        let _d = repo.put(SET_AI_ENABLED, "1", now)
        let o3 = repo.options(now)
        runner.check("③ 总开关打开后 enabled=true", o3.enabled)
        runner.check("③ 可用时理由为空", o3.disabledReason.size == 0)

        // ④ endpoint 非 https ⇒ 拒绝（明文调模型 = 密钥裸奔）
        let _e = repo.put(SET_AI_ENDPOINT, "http://api.example.com/v1", now)
        let o4 = repo.options(now)
        runner.check("★ ④ http:// endpoint 被拒（明文调模型 = 密钥裸奔）", !o4.enabled)
        /*
         * ★★ ④之二（2026-10-09 第十一份复查后新增）：
         *   拒绝理由里必须**说清"本版本没有明文放行开关"**。
         *
         *   ⚠ 为什么这是一条**要钉住的断言**（而不是"消息文案无所谓"）：
         *     上一版这里没有这句，而 `AiRuntimeOptions` 的注释写着
         *     "只能由启动参数置位" —— 那个参数**根本不存在**。
         *     于是运维（以及复查者本人）会去翻启动参数找一个不存在的开关，
         *     白白耗时间，最后得到的结论还是"不确定是不是我配错了"。
         *   📌 判据：**错误消息要能终止排查** —— 明确说"没有这条路"，
         *     比只说"不支持明文"有用：后者仍让人怀疑是不是有别的开关没找到。
         */
        runner.check("★★ ④ 且理由里明确说「不提供明文放行开关」（终止排查，不让人去翻启动参数）",
                     o4.disabledReason.contains("不提供"))
        runner.check("★★ ④ 且给出可行的替代（https 或本机反向代理终止 TLS）",
                     o4.disabledReason.contains("反向代理"))
        let _f = repo.put(SET_AI_ENDPOINT, "https://api.example.com/v1", now)

        // ⑤ 越界值必须被拒（照基线口径）
        let bounds: Array<(String, String, String)> = [
            (SET_AI_TIMEOUT, "0", "超时 0（无限等待）"),
            (SET_AI_TIMEOUT, "301", "超时 301（超过上界）"),
            (SET_AI_MAX_CONCURRENT, "0", "并发 0"),
            (SET_AI_MAX_CONCURRENT, "65", "并发 65（超过上界）"),
            (SET_AI_MAX_TOKENS, "63", "max_tokens 63（过小会截断输出）"),
            (SET_AI_MAX_TOKENS, "8193", "max_tokens 8193（超过上界）")
        ]
        // 每个数值项的"合法值"（写越界值前先恢复它）
        let okVals = HashMap<String, String>()
        okVals[SET_AI_TIMEOUT] = "30"
        okVals[SET_AI_MAX_CONCURRENT] = "4"
        okVals[SET_AI_MAX_TOKENS] = "2048"
        var allBad = true
        for ((k, v, why) in bounds) {
            /*
             * ★★ 复查第 1 条之后这里变了：越界值现在**写入即被拒**，
             *   所以"它会写进库并把 AI 变成不可用"这个旧前提**不再成立**。
             *   ⇒ 每次先把该值设回合法，再尝试写越界值：
             *     · 若写入被拒（400 语义）⇒ 后续仍可用 ⇒ 正确；
             *     · 若写入被接受 ⇒ 库里有越界值 ⇒ AI 应变成不可用（旧行为）。
             *   两种都对，但**不能**让它"既写进去又报可用"。
             */
            let _restore = repo.put(k, okVals[k], now)
            let w = repo.put(k, v, now)
            if (!w.ok) {
                // 写入即被拒 ⇒ 好；再确认库里的值仍是合法的
                if (!repo.options(now).enabled) {
                    allBad = false
                    println("        ★ 写越界值被拒，但 AI 反而不可用了（库被污染？）：${why}")
                }
            } else {
                // 被接受 ⇒ 必须表现为不可用
                if (repo.options(now).enabled) {
                    allBad = false
                    println("        ★ 未拦住：${why}")
                }
                let _fix = repo.put(k, okVals[k], now)
            }
        }
        let _restoreAll1 = repo.put(SET_AI_TIMEOUT, "30", now)
        runner.check("★ ⑤ 6 个越界值要么写入即被拒、要么使 AI 不可用（都不允许「静默接受」）", allBad)

        /*
         * ★★ ⑥ 数值项必须**写入即校验**（第七份复查第 1 条，我已复现）。
         *
         * 原来只校验 `key_ref`，数值项**完全不校验**：
         *     PUT ai.timeout_secs = abc  -> 200，回显 value=abc
         * 而运行期 `parseInt64Or` 把它**静默换成默认值 30**
         * ⇒ **回显的值 ≠ 生效的值**，而且系统报"配置有效"。
         *
         * 更能说明危害的是复查探到的真实时序：库里原来是越界的 9999
         * （正确地给出 enabled=false + 明确理由），把它"改成" abc 之后
         * **enabled 反而翻成了 true** —— 一个写错的编辑把报警变成了绿灯。
         *
         * ⚠ 本用例是**回归闸门**：没有它，将来"优化"掉 put() 里的校验就又漏了。
         */
        hResetAiSettings(db)
        let repo2 = AiSettingsRepo(db)
        // 先建立"配置齐全 + 总开关开"的可用状态
        let _e1 = repo2.put(SET_AI_ENDPOINT, "https://api.example.com/v1", now)
        let _e2 = repo2.put(SET_AI_MODEL, "m", now)
        let _e3 = repo2.put(SET_AI_KEY_REF, "env:AIKEY", now)
        let _e4 = repo2.put(SET_AI_ENABLED, "1", now)
        runner.check("⑥ 前置：配置齐全后 enabled=true", repo2.options(now).enabled)
        // ★ 非数字必须被拒（而不是写成 abc 后静默回落成 30）
        let numericBads: Array<(String, String)> = [
            (SET_AI_TIMEOUT, "abc"),
            (SET_AI_TIMEOUT, "30秒"),
            (SET_AI_TIMEOUT, ""),
            (SET_AI_MAX_TOKENS, "abc"),
            (SET_AI_MAX_CONCURRENT, "abc"),
            (SET_AI_MAX_CONCURRENT, "1.5"),
            (SET_AI_TIMEOUT, "9999"),          // 越界（复查探到的那个值）
            (SET_AI_TIMEOUT, "-1"),
            (SET_AI_MAX_TOKENS, "100000")
        ]
        var allRejected2 = true
        for ((k, v) in numericBads) {
            let r = repo2.put(k, v, now)
            // 空值是"回到默认值"的显式例外，允许
            if (v.trimAscii().size == 0) {
                continue
            }
            if (r.ok) {
                allRejected2 = false
                println("        ★ 未拒绝：${k} = '${v}'")
            }
        }
        runner.check("★★ ⑥ 8 个非数字/越界值全部**写入即被拒**（不再静默回落）", allRejected2)
        /*
         * ★★ ⑥b 真正的回归闸门：**回显值必须等于生效值**。
         *
         * 原缺陷破坏的就是这条不变量：回显 `abc`（库里存的）、生效 30（回落后的）。
         *
         * ⚠ 注意"空值"这条路径**不属于**不一致 —— 空值是"删掉该行"的等价写法，
         *   此时 `get` 返回**默认值字符串**（"30"），而生效值也是 30 ⇒ **仍然一致**。
         *   我第一版断言写成"库里必须有非空合法值"，于是空值那条把断言弄红了 ——
         *   那是**断言写错了**（把"一致"错写成"非空"），不是实现有问题。
         */
        let repo3 = AiSettingsRepo(db)
        let _t0 = repo3.put(SET_AI_TIMEOUT, "45", now)
        let shown = repo3.get(SET_AI_TIMEOUT, now)
        let effective = repo3.options(now).timeoutSecs
        runner.check("★★ ⑥b 非空值时：回显值与生效值一致（'${shown}' vs ${effective}）",
                     aiIsAllDigits(shown) && parseInt64Or(shown, -1) == effective)
        runner.check("★★ ⑥b 且生效值就是写入的 45（没有被静默回落）", effective == 45)
        // ★ 空值被接受＝回默认值（显式例外，不能变成 400）
        let blankOk = repo3.put(SET_AI_TIMEOUT, "   ", now)
        runner.check("★ ⑥b 空值被接受（表示回到默认值），不是 400", blankOk.ok)
        /*
         * ⚠ 这里断言的是**接口回显**，不是 `repo.get()` 的原始值 —— 两者语义不同：
         *   · `repo.get()` = "库里的原始值"（为空表示"没设"）
         *   · 接口回显 = "**生效值**"（为空则显示默认值）
         *   我第一版拿 `repo.get()` 的原始值去比，于是"空值 ⇒ 回显默认"这条正确的
         *   行为被我的断言判成了不一致 —— **断言写错了对象**。
         *   📌 教训：断言"回显 == 生效"时，要断言**回显接口的输出**，不是内部 getter。
         */
        let effective2 = repo3.options(now).timeoutSecs
        let view2 = aiSettingsJson(repo3, now)
        var timeoutShown = ""
        let items = view2.get("items").getOrThrow().asArray()
        var k: Int64 = 0
        let itemCount = items.size()
        while (k < itemCount) {
            let it = items[k].asObject()
            if (it.get("key").getOrThrow().asString().getValue() == SET_AI_TIMEOUT) {
                timeoutShown = it.get("value").getOrThrow().asString().getValue()
            }
            k = k + 1
        }
        runner.check("★★ ⑥b 空值（=回默认）时**接口回显值 == 生效值**（'${timeoutShown}' vs ${effective2}）",
                     aiIsAllDigits(timeoutShown) && parseInt64Or(timeoutShown, -1) == effective2)
        runner.check("★ ⑥b 且确实回到了默认值 30", effective2 == 30)
    })
}

/*
 * AC-P3-4 回显脱敏：管理员能看到配置，但**看不到秘密**。
 *
 * ⚠ 为什么连管理员也不给：与"账号接口绝不回 pw_hash"同一条纪律 ——
 *   口令/密钥的**材料**没有任何前端用途，回它只是给泄露多开一条路。
 */
public func acP3_4(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-4 回显脱敏 ===")
    runner.section("AC-P3-4", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let repo = AiSettingsRepo(db)
        let _a = repo.put(SET_AI_ENDPOINT, "https://api.example.com/v1/chat?token=SECRET_TOKEN_XYZ", now)
        let _b = repo.put(SET_AI_KEY_REF, "env:MY_SECRET_KEY_NAME", now)
        let view = aiSettingsJson(repo, now).toString()
        // ① 密钥引用名不出现
        runner.check("★★ ① 回显不含密钥引用的变量名", !view.contains("MY_SECRET_KEY_NAME"))
        // ② ★ endpoint 的**查询串**不得出现（有些网关把 key 放 ?api-key=）
        runner.check("★★ ② 回显不含 endpoint 的查询串（可能含凭据）",
                     !view.contains("SECRET_TOKEN_XYZ"))
        /*
         * ★★ ②之二（2026-10-09 第十一份复查后新增）：**路径必须保留**。
         *
         * ⚠ 原来这里断言的是"只有 host"，而那条口径**过度脱敏**了：
         *   它把路径也抹掉 ⇒ 管理员看不到自己配的是哪条路径。
         *   复查也确认"生效值没有被截断"（`o.endpoint` 是原样交给 `url(...)`），
         *   所以抹掉路径**没有安全收益**，只有可用性损失。
         *
         * ⚠ 为什么这条断言值得单列（不是"文案偏好"）：
         *   brief §2.1 第 4 条要求**对话模型与向量模型分开配** ——
         *   两者很可能是**同一 host 的不同路径**（`/v1/chat/completions` vs
         *   `/v1/embeddings`）。只回显 host 的话，管理员盯着两个一样的
         *   `https://api.example.com` **无法确认有没有配反**；
         *   而配反的后果是"检索永远走关键词 / 模型永远不回答"，
         *   排查方向与真实原因**完全对不上**（本仓最忌的那类）。
         *   📌 判据：**回显要足以让配置者核对「我配对了没有」** ——
         *     该抹的只有**凭据**，路径不是凭据。
         */
        runner.check("★★ ② 回显**保留路径**（管理员要能核对配的是哪条，实得含 /v1/chat=${view.contains("/v1/chat")}）",
                     view.contains("/v1/chat"))
        runner.check("★ ② 且不含查询串（`token=` 后面的东西一律不出现）", !view.contains("token="))
        runner.check("② 回显里的 endpoint 含 host", view.contains("api.example.com"))
        /*
         * ★★ ②之三：直接钉 `aiSafeHost` 的**四个边界**（它现在多了一道 userinfo 处理）。
         *
         * ⚠ userinfo 是**最直白的凭据形态**（`https://user:pass@host/`），
         *   而它**不是查询串** ⇒ 原来"只取 scheme://host"的实现顺带挡住了它，
         *   改成"保留路径"之后就必须**显式**挡 —— 否则这次改动会**引入一个泄露**。
         *   📌 教训：**放宽一个脱敏规则时，要重新检查原来"顺带被挡住"的东西**。
         *     （原来挡住的可能不止是你想放开的那些。）
         */
        runner.check("★★ ② aiSafeHost 抹掉 userinfo 凭据",
                     !aiSafeHost("https://user:pass@api.example.com/v1/chat").contains("pass"))
        runner.check("★★ ② 且仍保留 host 与路径",
                     aiSafeHost("https://user:pass@api.example.com/v1/chat") ==
                     "https://api.example.com/v1/chat")
        runner.check("★ ② 密码含 `@` 时也抹干净（取**最后一个** @）",
                     !aiSafeHost("https://user:p@ss@api.example.com/v1").contains("ss@"))
        runner.check("★ ② 抹掉查询串与 fragment",
                     aiSafeHost("https://h/v1/chat?api-key=K#frag") == "https://h/v1/chat")
        runner.check("★ ② 无路径时就是 scheme://host",
                     aiSafeHost("https://h") == "https://h")
        runner.check("★ ② 空串 ⇒ 空串（不抛）", aiSafeHost("").size == 0)
        // ③ 非秘密项的值应当能看到（否则管理员没法核对配置）
        runner.check("③ 非秘密项（endpoint）的值可见", view.contains("api.example.com"))
        // ④ 秘密项只给"设置了没有"与引用类型
        runner.check("④ 秘密项标了 set=true", view.contains("\"set\":true"))
        runner.check("④ 秘密项 ref_kind=env", view.contains("\"ref_kind\":\"env\""))
    })
}

/* ===================== P3 第二块：Prompt 模板 + 工具开关 ===================== */

/*
 * AC-P3-5 ★★ Prompt 模板：**缺占位符的模板存不进去**。
 *
 * 这条守的是"AI 变笨"这类**最难查**的故障：模板漏了 `{主诉}` 不会报错、
 * 不会崩溃，只是模型收到一段没有患者信息的人设，输出看起来正常但完全没用。
 * ⇒ 所以把"必需占位符"写成契约，写入时就拦。
 */
public func acP3_5(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-5 ★★ Prompt 模板（占位符校验 + 零重启）===")
    runner.section("AC-P3-5", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let settings = AiSettingsRepo(db)
        let repo = PromptRepo(settings)

        // ① 默认模板必须**自身合法**（否则"默认值"这条路会把校验绕过去）
        var defaultsOk = true
        for (s in promptSlots()) {
            let body = promptDefaultBody(s.name)
            for (ph in s.required) {
                if (!body.contains(ph)) {
                    defaultsOk = false
                    println("        默认模板 ${s.name} 缺 ${ph}")
                }
            }
        }
        runner.check("★★ ① 每个默认模板都含齐它的必需占位符（默认值不能绕过校验）", defaultsOk)

        /*
         * ★★ ①b **三个默认模板必须两两不同**（结构断言 —— 守的是语言陷阱，不是业务）。
         *
         * 我原来用 `match (name) { case PROMPT_DEPT => ... }` 分派默认模板，
         * 而 `PROMPT_DEPT` 是 **String 常量** ⇒ 实测发现它被当成 **catch-all 绑定**，
         * 于是 `promptDefaultBody("previsit")` **一直返回 dept 的模板**。
         * 上面 ① 那条断言把它抓出来了（previsit 模板缺自己的占位符）。
         *
         * 但 ① 是"**碰巧**"抓到的（因为两个模板的占位符不同）。要**直接**守住这个陷阱，
         * 就该断言"不同名字给出不同模板" —— 那正是 catch-all 会破坏的性质。
         * 三条模板内容本来就不同，所以这个断言永远是良性的；而一旦有人把分派改回
         * `match` + 常量标签，它会立刻变红。
         */
        let bodies = ArrayList<String>()
        for (s in promptSlots()) {
            bodies.add(promptDefaultBody(s.name))
        }
        var distinct = true
        var i: Int64 = 0
        while (i < bodies.size) {
            var j: Int64 = i + 1
            while (j < bodies.size) {
                if (bodies[i] == bodies[j]) {
                    distinct = false
                }
                j = j + 1
            }
            i = i + 1
        }
        runner.check("★★ ①b 三个默认模板两两不同（守住「String 常量当 match 标签会变 catch-all」这个陷阱）",
                     distinct)

        // ② ★ 缺占位符的模板必须被拒
        let badTemplates: Array<(String, String, String)> = [
            (PROMPT_DEPT, "你是导诊助手，请推荐科室：{候选科室}", "缺 {主诉}"),
            (PROMPT_DEPT, "你是导诊助手，患者主诉：{主诉}", "缺 {候选科室}"),
            (PROMPT_PREVISIT, "患者主诉：{主诉}，请追问", "缺 {已有信息} 与 {待问项}"),
            (PROMPT_REDFLAG, "请判断是否需要立即就医", "缺 {主诉}")
        ]
        var allRejected = true
        for ((n, body, why) in badTemplates) {
            let r = repo.put(n, body, now)
            if (r.ok) {
                allRejected = false
                println("        ★ 未拒绝（${why}）：${n}")
            }
        }
        runner.check("★★ ② 4 个缺占位符的模板全部被拒（防「AI 静默变笨」）", allRejected)

        // ③ 合法模板能存；且**立刻**生效（零重启）
        let good = "患者主诉：{主诉}\n候选科室：{候选科室}\n请只输出 JSON。"
        let w = repo.put(PROMPT_DEPT, good, now)
        runner.check("③ 合法模板被接受", w.ok)
        runner.check("★★ ③ 同一实例立刻读到新模板（零重启）", repo.body(PROMPT_DEPT, now) == good)
        runner.check("③ customized = true", repo.customized(PROMPT_DEPT, now))
        // ④ 未改过的仍报默认模板
        runner.check("④ 未改过的模板返回默认正文且 customized=false",
                     repo.body(PROMPT_REDFLAG, now).size > 0 && !repo.customized(PROMPT_REDFLAG, now))
        // ⑤ 恢复默认
        let _r = repo.reset(PROMPT_DEPT, now)
        runner.check("⑤ 恢复默认后正文 == 默认模板", repo.body(PROMPT_DEPT, now) == promptDefaultBody(PROMPT_DEPT))
        runner.check("⑤ 且 customized 回到 false", !repo.customized(PROMPT_DEPT, now))
        // ⑥ 未知 Prompt 被拒
        runner.check("⑥ 未知 Prompt 被拒", !repo.put("no_such_prompt", "x", now).ok)
        // ⑦ 长度上限按**字符**算（用中文，避免"按字节"误判）
        let longBody = hRepeatChar("持", 4001) + "{主诉}{候选科室}"
        runner.check("★ ⑦ 超长模板被拒（按字符数算，中文不误伤）", !repo.put(PROMPT_DEPT, longBody, now).ok)
        let okLen = hRepeatChar("持", 3900) + "{主诉}{候选科室}"
        runner.check("★ ⑦ 但 3900 字符 + 占位符被接受", repo.put(PROMPT_DEPT, okLen, now).ok)
        let _c = repo.reset(PROMPT_DEPT, now)
    })
}

/*
 * AC-P3-6 ★★ 工具开关：**被禁用的工具必须真的不可用**。
 *
 * ⚠ 这是本组最关键的一条：开关"看起来生效了"（接口返回了 enabled=false）
 *   与"真的不可用"（判据函数返回 false）是**两件事**。
 *   所以断言必须打在**判据函数**上，而不是接口回显上。
 */
public func acP3_6(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-6 ★★ AI 工具开关（禁用即真的不可用）===")
    runner.section("AC-P3-6", { =>
        hResetAiSettings(db)
        let now = hNowEpoch()
        let settings = AiSettingsRepo(db)

        // ① 默认全开
        runner.check("① 默认全部启用（${aiToolEnabledCount(settings, now)} / ${aiToolToggles().size}）",
                     aiToolEnabledCount(settings, now) == aiToolToggles().size)
        // ② ★ 关掉一条 ⇒ **判据函数**必须返回 false
        let target = "bookable_slots"
        let w = aiToolSet(settings, target, false, now)
        runner.check("② 关闭 ${target} 成功", w.ok)
        runner.check("★★ ② 判据函数真的返回 false（不是只改了回显）",
                     !aiToolEnabled(settings, target, now))
        runner.check("② 其它工具不受影响（抽查 redflag_scan 仍为 true）",
                     aiToolEnabled(settings, "redflag_scan", now))
        runner.check("② 已启用数减 1（${aiToolEnabledCount(settings, now)}）",
                     aiToolEnabledCount(settings, now) == aiToolToggles().size - 1)
        // ③ 再打开 ⇒ 恢复
        let _w2 = aiToolSet(settings, target, true, now)
        runner.check("③ 重新打开后判据恢复 true", aiToolEnabled(settings, target, now))
        // ④ ★ 未登记的工具**不可用**（白名单纪律：模型不能新增工具）
        runner.check("★★ ④ 未登记的工具判据为 false（不存在的工具不会「默认可用」）",
                     !aiToolEnabled(settings, "delete_all_patients", now))
        runner.check("④ 也无法开关未登记的工具", !aiToolSet(settings, "no_such_tool", true, now).ok)
        // ⑤ ★ 值被写坏 ⇒ **从严判为关**（失败方向选安全的那侧）
        let _bad = settings.put(AI_TOOL_KEY_PREFIX + target, "abc", now)
        runner.check("★★ ⑤ 库里是垃圾值（abc）⇒ 从严判为**关**（只有明确的 1 才算开）",
                     !aiToolEnabled(settings, target, now))
        let _z = settings.put(AI_TOOL_KEY_PREFIX + target, "0", now)
        runner.check("⑤ 显式 0 ⇒ 关", !aiToolEnabled(settings, target, now))
        let _o = settings.put(AI_TOOL_KEY_PREFIX + target, "1", now)
        runner.check("⑤ 显式 1 ⇒ 开", aiToolEnabled(settings, target, now))
        // ⑥ ★ 开关**零重启**：写后同一实例立刻生效
        runner.check("★★ ⑥ 开关零重启（写后立即生效，无需重启）",
                     aiToolEnabled(settings, target, now))
    })
}