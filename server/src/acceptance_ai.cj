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
import stdx.encoding.json.*

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
        /*
         * ★ 2026-10-17（评审整改）：默认值不再是空串 —— 现在默认就是内置的
         *   DeepSeek 端点（`AI_BUILTIN_DEFAULT_ENDPOINT`），所以"未配置"读到的
         *   是**开箱即用**的那个值。断言跟着改口径，但仍然钉住关键点：
         *   读到的必须恰好是默认值本身（不能是脏值、也不能是空）。
         */
        runner.check("① 未配置时读到默认值（内置 DeepSeek 端点，开箱即用）",
                     v1 == AI_BUILTIN_DEFAULT_ENDPOINT)
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
        /*
         * ★ 2026-10-17：删行 = 回默认（内置端点）；"清空"仍然是另一件事
         *   （写空串 = 停用 AI）。这两条**口径不同**，见 `AiSettingsRepo.get()` 注释，
         *   这里把两者都钉住，免得以后有人把"删行"当成"清空"。
         */
        runner.check("④ 删除后回到默认值（内置 DeepSeek 端点）",
                     repo.get(SET_AI_ENDPOINT, now) == AI_BUILTIN_DEFAULT_ENDPOINT)
        let _z = repo.put(SET_AI_ENDPOINT, "", now)
        runner.check("④之二 写空串 ≠ 删行：空串是**显式停用**，读到的是空",
                     repo.get(SET_AI_ENDPOINT, now).size == 0)
        let _rz = repo.remove(SET_AI_ENDPOINT, now)

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
 * ⚠ 边界值照抄搬迁前 `aiValidate`（每条背后都有实测踩出来的理由）——
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

        /*
         * ① 全新库 ⇒ **开箱即用**（2026-10-17 评审整改后的口径）。
         *   评审批评"默认零模型调用、智能深度无法现场证明"，所以默认值改成了
         *   内置密钥引用 `builtin:demo` + DeepSeek 端点 + 总开关 1。
         *   断言要钉住"默认确实可用"，否则"开箱即用"只是文档里的一句话。
         */
        let o1 = repo.options(now)
        runner.check("① 未配置时 enabled=true（默认 key_ref = builtin:demo ⇒ 开箱即用）", o1.enabled)
        runner.check("① 开箱即用用的就是内置 DeepSeek 端点", o1.endpoint == AI_BUILTIN_DEFAULT_ENDPOINT)
        runner.check("① 开箱即用用的是内置模型名", o1.model == AI_BUILTIN_DEFAULT_MODEL)
        runner.check("① 开箱即用不留「不可用理由」", o1.disabledReason.size == 0)
        // ①之二 显式清空 endpoint ⇒ 不可用，理由提到 endpoint
        let _z = repo.put(SET_AI_ENDPOINT, "", now)
        let o1b = repo.options(now)
        runner.check("① 清空 endpoint ⇒ enabled=false", !o1b.enabled)
        runner.check("① 理由非空且提到 endpoint", o1b.disabledReason.contains(SET_AI_ENDPOINT))

        // ② 配齐但**总开关为 0** ⇒ 不可用，且理由说清是开关
        let _a = repo.put(SET_AI_ENDPOINT, "https://api.example.com/v1", now)
        let _b = repo.put(SET_AI_MODEL, "m", now)
        let _c = repo.put(SET_AI_KEY_REF, "env:AIKEY", now)
        /* ★ 2026-10-17：默认总开关已是 1 ⇒ 这里必须**显式**关掉才谈得上"开关为 0"。 */
        let _off = repo.put(SET_AI_ENABLED, "0", now)
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

        // ⑤ 越界值必须被拒（照搬迁前口径）
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

/* ===================== AC-P3-7：分诊遥测与排障（改进 7）===================== */

/*
 * JSON 取值小工具。
 *
 * ⚠ 缺字段一律回"**不可能的值**"（-1 / `<缺字段>`），**不回**看起来正常的默认值：
 *   如果回 0/空串，那么"这个字段压根没写进响应"会被断言悄悄放过 ——
 *   而"字段名写错"正是这类改动最常见的缺陷。
 * ⚠ `JsonObject.get` 返回 `?JsonValue` ⇒ 必须先 match 再判类型
 *   （本仓的坑：直接对 Option 调 `asInt()` 会报
 *    `'asInt' is not a member of enum 'Option<...>'`）。
 */
func hT7JsonInt(o: JsonObject, key: String): Int64 {
    match (o.get(key)) {
        case Some(jv) =>
            if (jv is JsonInt) {
                return jv.asInt().getValue()
            }
            return -1
        case None => return -1
    }
}

func hT7JsonStr(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(jv) =>
            if (jv is JsonString) {
                return jv.asString().getValue()
            }
            return "<非字符串>"
        case None => return "<缺字段>"
    }
}

func hT7JsonBool(o: JsonObject, key: String): Bool {
    match (o.get(key)) {
        case Some(jv) =>
            if (jv is JsonBool) {
                return jv.asBool().getValue()
            }
            return false
        case None => return false
    }
}

func hT7JsonFloat(o: JsonObject, key: String): Float64 {
    match (o.get(key)) {
        case Some(jv) =>
            if (jv is JsonFloat) {
                return jv.asFloat().getValue()
            }
            return -1.0
        case None => return -1.0
    }
}

/* 数一数配置表里**真配置项**的行数（保留行不算 —— 它不是配置项）。 */
func hT7SettingRows(db: DbBackend): Int64 {
    let rs = db.query("SELECT COUNT(*) FROM ai_setting WHERE k <> ?", [DbStr(SET_AI_REVISION_ROW)])
    return rs.getInt(0, 0)
}

/* 取嵌套对象（缺字段/类型不符回**空对象** ⇒ 里面的取值会回 -1/`<缺字段>`）。 */
func hT7Sub(o: JsonObject, key: String): JsonObject {
    match (o.get(key)) {
        case Some(jv) =>
            if (jv is JsonObject) {
                return jv.asObject()
            }
            return JsonObject()
        case None => return JsonObject()
    }
}

/* 取 `groups` 数组的第 i 个元素（越界回空对象）。 */
func hT7GroupAt(o: JsonObject, i: Int64): JsonObject {
    match (o.get("groups")) {
        case Some(jv) =>
            if (jv is JsonArray) {
                let arr = jv.asArray()
                if (i < arr.size()) {
                    return arr[i].asObject()
                }
            }
            return JsonObject()
        case None => return JsonObject()
    }
}

/*
 * AC-P3-7 ★★ 分诊遥测：**调用事实**可排障，而主诉仍然一个字都不落库。
 *
 * ── 这条守的是什么 ────────────────────────────────────────────────────────
 *   改进 7 往 `triage_stat` 加了七列排障遥测（请求号 / 模型 / 模板版本 / 耗时 /
 *   降级原因 / 是否用知识库 / 命中的文档 id）。它一次开了**两个**风险口：
 *     ① **隐私**：列变多了，主诉原文会不会"顺手"被记进去？
 *     ② **口径**：数字记错了比不记更坏 —— 一个错的 p95 会让整场排障走偏。
 *   所以断言分三块：**隐私否定断言**、**逐字段往返**、**统计量可手算**。
 *
 * ── 为什么分位数要"可手算"（本组的核心手法）──────────────────────────────
 *   样本是我自己造的 5 个已知耗时 [0, 120, 200, 310, 450]。最近秩法下
 *   p50 = 第 ⌈0.5×5⌉ = 3 个 = 200、p95 = 第 ⌈0.95×5⌉ = 5 个 = 450。
 *   如果实现改成"线性插值"，p50 会给出 200（巧合相同）但 p95 会给出
 *   450 与 310 之间的插值 ⇒ 断言里那两个**精确值**会立刻变红。
 *   📌 断言"统计量 == 手算值"能让实现方式的分歧暴露出来，而
 *      "p50 >= p0 && p50 <= p95"这种松断言对任何实现都成立。
 */
public func acP3_7(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P3-7 ★★ 分诊遥测：排障可见，主诉仍不落库 ===")
    runner.section("AC-P3-7", { =>
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        db.exec("DELETE FROM ai_model", Array<DbValue>())
        hResetAiSettings(db)
        let ts = TriageStatRepo(db)
        let now = hNowEpoch()

        /*
         * ① 造 5 行**已知**样本：3 行走模型（其中 2 行降级为 0）、1 行规则兜底、
         *    1 行模型输出非法。两行共用 `ac7-req-a`（专门用来验"同一请求多行"）。
         */
        ts.record("OK", false, "呼吸内科", false, "model", now, requestId: "ac7-req-a",
                  modelId: 7, modelName: "通义千问-正式", promptRevision: 3, elapsedMs: 120,
                  usedKb: true, kbDocIds: "11,22")
        ts.record("OK", false, "心内科", false, "model", now, requestId: "ac7-req-a",
                  modelId: 7, modelName: "通义千问-正式", promptRevision: 3, elapsedMs: 200)
        ts.record("OK", false, "消化内科", true, "model", now, requestId: "ac7-req-b",
                  modelId: 9, modelName: "备用模型", promptRevision: 3, elapsedMs: 310,
                  usedKb: true, kbDocIds: "33")
        ts.record("RED_FLAG", true, "急诊科", false, "rules", now, requestId: "ac7-req-c",
                  promptRevision: 3, degradeReason: "RED_FLAG")
        ts.record("NO_DEPT", false, "", false, "model:invalid", now, requestId: "ac7-req-c",
                  modelId: 7, modelName: "通义千问-正式", promptRevision: 3, elapsedMs: 450,
                  degradeReason: "INVALID_OUTPUT")
        runner.check("① 五行样本已写入（实得 ${ts.count()} 行）", ts.count() == 5)

        // ② 逐字段往返：**存进去什么，取出来就是什么**（新列全部走一遍）
        let from = now - 60
        let to = now + 60
        let w = ts.windowRows(from, to, 100)
        runner.check("② 窗口取回 5 行且未被截断（实得 ${w.rows.size} 行，truncated=${w.truncated}）",
                     w.rows.size == 5 && !w.truncated)
        // 同一 created_at 时按 id DESC ⇒ 第一行是最后插入的那条
        let newest = w.rows[0]
        runner.check("② 最新一行 = 输出非法那条（source='${newest.source}'、" +
                     "degrade='${newest.degradeReason}'）",
                     newest.source == "model:invalid" && newest.degradeReason == "INVALID_OUTPUT" &&
                     newest.requestId == "ac7-req-c" && newest.elapsedMs == 450)
        // 找出"用了知识库且带文档 id"的那行
        var kbRow = TriageCallRow()
        var foundKb = false
        for (r in w.rows) {
            if (r.usedKb && r.kbDocIds.size > 0) {
                kbRow = r
                foundKb = true
            }
        }
        runner.check("② used_kb / kb_doc_ids 往返一致（实得 '${kbRow.kbDocIds}'）",
                     foundKb && (kbRow.kbDocIds == "11,22" || kbRow.kbDocIds == "33"))
        runner.check("② 模型行标识往返一致（实得 id=${kbRow.modelId} name='${kbRow.modelName}'）",
                     kbRow.modelId > 0 && kbRow.modelName.size > 0 &&
                     kbRow.promptRevision == 3)
        runner.check("② 未降级行的 degrade_reason 是**空串**（= 真用上了模型；实得 " +
                     "'${kbRow.degradeReason}'，长度 ${kbRow.degradeReason.size}）",
                     kbRow.degradeReason.size == 0)

        // ③ 统计量：**手算值**逐一对账（见函数头"为什么可手算"）
        let agg = triageStatAggregate(w.rows, "source", 20)
        let all = agg[0]
        runner.check("③ 总体样本数 = 5（实得 ${all.total}）", all.total == 5)
        /*
         * ⚠ 2026-10-16（复核提示项）后，"降级"只算**模型侧失败**：
         *   RED_FLAG 是"规则直接判红标、压根没调模型"的良性安全旁路，单独计入
         *   `redFlag`。少算/多算都会让看板上的 AI 失败率失真：把红标算进去 ⇒
         *   临床看到"AI 总在失败"（实际是规则在正常拦截）；把真失败漏掉 ⇒
         *   模型坏了也没人知道。样本里 rules 那行正是 RED_FLAG 旁路。
         */
        runner.check("★ ③ 降级数 = 1（只有 model:invalid 那行是真降级；rules 那行是 RED_FLAG 安全旁路，" +
                     "实得 degraded=${all.degraded} redFlag=${all.redFlag}）",
                     all.degraded == 1 && all.redFlag == 1)
        runner.check("★ ③ p50 = 200（最近秩第 3 个；实得 ${all.p50Ms}）", all.p50Ms == 200)
        runner.check("★ ③ p95 = 450（最近秩第 5 个；实得 ${all.p95Ms}）", all.p95Ms == 450)

        // ④ 分组：按 source 三组，按样本量降序、并列按 bucket 升序（顺序必须确定）
        let groups = agg[1]
        runner.check("④ 按 source 分出 3 组（实得 ${groups.size}）", groups.size == 3)
        if (groups.size == 3) {
            runner.check("④ 第 1 组 = model（3 条，0 降级；实得 '${groups[0].bucket}'/" +
                         "${groups[0].total}/${groups[0].degraded}）",
                         groups[0].bucket == "model" && groups[0].total == 3 &&
                         groups[0].degraded == 0)
            runner.check("④ 第 2 组 = model:invalid（并列时按名字升序 ⇒ 顺序确定）",
                         groups[1].bucket == "model:invalid")
            runner.check("④ 第 3 组 = rules（降级 0 —— RED_FLAG 不算降级；红标旁路 = 1）",
                         groups[2].bucket == "rules" && groups[2].degraded == 0 &&
                         groups[2].redFlag == 1)
        } else {
            runner.check("④ 分组数应为 3", false)
        }

        /*
         * ⑤ `group_by` 是**安全边界**：列名要拼进 SQL，所以只认白名单里的三个。
         *   ⚠ 非法值必须**判否**（由 HTTP 层回 400），绝不"回退默认值继续查"。
         */
        runner.check("⑤ 白名单接受 source / reason_code / model_name",
                     triageStatGroupByOk("source") && triageStatGroupByOk("reason_code") &&
                     triageStatGroupByOk("model_name"))
        runner.check("★★ ⑤ 白名单拒绝空串、注入串与其它列（含 id/department）",
                     !triageStatGroupByOk("") && !triageStatGroupByOk(";DROP TABLE triage_stat") &&
                     !triageStatGroupByOk("id") && !triageStatGroupByOk("department"))

        // ⑥ 返回体形状（HTTP 层就是把这个对象塞进 data）
        let jo = triageStatWindowJson(w, "source", from, to, 100, 20)
        runner.check("⑥ 回显窗口参数（from/to/group_by/sample_limit）",
                     hT7JsonInt(jo, "from") == from && hT7JsonInt(jo, "to") == to &&
                     hT7JsonStr(jo, "group_by") == "source" &&
                     hT7JsonInt(jo, "sample_limit") == 100)
        runner.check("⑥ sampled = 5、truncated = false（**没被截断就不许报截断**）",
                     hT7JsonInt(jo, "sampled") == 5 && !hT7JsonBool(jo, "truncated"))
        let overall = hT7Sub(jo, "overall")
        runner.check("⑥ overall 的 total/degraded/red_flag/p50/p95 与聚合一致",
                     hT7JsonInt(overall, "total") == 5 && hT7JsonInt(overall, "degraded") == 1 &&
                     hT7JsonInt(overall, "red_flag") == 1 &&
                     hT7JsonInt(overall, "p50_ms") == 200 && hT7JsonInt(overall, "p95_ms") == 450)
        // 两个比率是**分开的**：degrade_rate 回答"模型坏没坏"，red_flag_rate 回答"多少单被安全旁路拦下"。
        let rate = hT7JsonFloat(overall, "degrade_rate")
        runner.check("⑥ 降级率 = 1/5 = 0.2（实得 ${rate}）", rate > 0.1999 && rate < 0.2001)
        let rfRate = hT7JsonFloat(overall, "red_flag_rate")
        runner.check("★★ ⑥ 红标旁路率 = 1/5 = 0.2（实得 ${rfRate}）—— 把 RED_FLAG 混进降级率会得 0.4，" +
                     "看板就会把「规则正常拦截」报成「AI 失败」", rfRate > 0.1999 && rfRate < 0.2001)
        let g0 = hT7GroupAt(jo, 0)
        runner.check("⑥ groups[0] 是 model 组（bucket/total 都对）",
                     hT7JsonStr(g0, "bucket") == "model" && hT7JsonInt(g0, "total") == 3)
        runner.check("⑥ 分组数上限字段回显（group_limit = 20）", hT7JsonInt(jo, "group_limit") == 20)

        /*
         * ⑦ ★★ 隐私否定断言（本组最重要的方向）。
         *   逐条列出"绝不能出现在响应里"的键名 —— 这份清单是**枚举**的，
         *   不是"记得别写"：将来有人加字段时，只要名字落在这几类里就会变红。
         */
        let text = jo.toString()
        runner.check("★★ ⑦ 响应里没有 patient_id / doctor_id / phone / 姓名形状的键",
                     !text.contains("patient_id") && !text.contains("doctor_id") &&
                     !text.contains("phone") && !text.contains("\"name\""))
        runner.check("★★ ⑦ 响应里没有 complaint / 主诉字段（本表根本没有这一列）",
                     !text.contains("complaint") && !text.contains("主诉"))
        let callJson = triageCallJson(newest).toString()
        runner.check("★★ ⑦ 单次调用视图同样干净（且不含知识库正文片段字段）",
                     !callJson.contains("complaint") && !callJson.contains("patient_id") &&
                     !callJson.contains("content"))
        runner.check("⑦ 单次调用视图带齐排障字段（request_id/model/prompt_revision/耗时/降级）",
                     callJson.contains("request_id") && callJson.contains("model_name") &&
                     callJson.contains("prompt_revision") && callJson.contains("elapsed_ms") &&
                     callJson.contains("degrade_reason") && callJson.contains("used_kb") &&
                     callJson.contains("kb_doc_ids"))
        // 表结构层面：没有任何自由文本列（与 AC-P4-4 同口径，这里是加重申明）
        let cols = db.query(
            "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() " +
            "AND TABLE_NAME = 'triage_stat' AND (COLUMN_NAME LIKE '%complaint%' " +
            "OR COLUMN_NAME LIKE '%text%' OR COLUMN_NAME LIKE '%note%')", Array<DbValue>())
        runner.check("★★ ⑦ 加完七列之后表结构**仍然**没有自由文本列（实得 ${cols.getInt(0, 0)} 列）",
                     cols.getInt(0, 0) == 0)

        // ⑧ 按请求号反查：同一 requestId 的多行都要出来，且新→旧
        let byReq = ts.callsByRequest("ac7-req-a", 20)
        runner.check("⑧ 同一 requestId 的 2 行都取到（实得 ${byReq.size} 行）", byReq.size == 2)
        if (byReq.size == 2) {
            runner.check("⑧ 且按 id 降序（新→旧；实得 ${byReq[0].id} > ${byReq[1].id}）",
                         byReq[0].id > byReq[1].id)
            runner.check("⑧ 两行都带着同一个 request_id",
                         byReq[0].requestId == "ac7-req-a" && byReq[1].requestId == "ac7-req-a")
        } else {
            runner.check("⑧ 同一 requestId 应取到 2 行", false)
        }
        runner.check("★★ ⑧ 未知 requestId 回**空数组**（不抛异常、也不假装 404）",
                     ts.callsByRequest("ac7-nope", 20).size == 0)
        runner.check("⑧ limit 生效（limit=1 ⇒ 只回 1 行）", ts.callsByRequest("ac7-req-a", 1).size == 1)

        /*
         * ⑧b ★★ 超长请求号的**读写同口径**（2026-10-16 复核 D2）。
         *   为什么值得单独一个用例：`X-Request-Id` 是客户端可控、长度不限的头，
         *   写侧截到 64（列宽）而读侧不截 ⇒ 排障闭环出现最坏的形态 ——
         *   **调用当场对得上号，事后怎么查都查不到**（triage_stat.cj 的注释
         *   早就预言过这个坑，但当时只有写侧做了截断）。
         *   这里不依赖 HTTP 层：直接写一行 64 字符的记录，再用**更长的** id 去查。
         */
        // 60 个 x 写字面量（不用 String.repeat —— 本仓没有先例，不值得为测试引入未验证的 API）
        let longKey = "ac7-long-" +
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        let storedKey = previsitTruncateChars(longKey, TRIAGE_REQUEST_ID_MAX)
        runner.check("⑧b 夹具本身确实超长（${longKey.size} 字符）、截断后正好是上限 ${TRIAGE_REQUEST_ID_MAX}",
                     longKey.size > TRIAGE_REQUEST_ID_MAX && storedKey.size == TRIAGE_REQUEST_ID_MAX)
        ts.record("OK", false, "急诊科", false, "model", now, requestId: longKey,
                  modelId: 7, modelName: "通义千问-正式", promptRevision: 3, elapsedMs: 88)
        let byLong = ts.callsByRequest(longKey, 20)
        runner.check("★★ ⑧b 用**完整超长** id 反查得到那一行（读侧不截时这里是 0 行）",
                     byLong.size == 1 && byLong[0].requestId == storedKey)
        runner.check("⑧b 落库的是截断后的 id（库里没有超长行）",
                     ts.callsByRequest(storedKey, 20).size == 1)
        db.exec("DELETE FROM triage_stat WHERE request_id = ?", [DbStr(storedKey)])

        // ⑨ 截断信号：抽样上限真的取到 limit+1 时，必须如实标记 truncated
        let w2 = ts.windowRows(from, to, 2)
        runner.check("★ ⑨ limit=2 时 rows=2 且 **truncated=true**（少算必须说出来）",
                     w2.rows.size == 2 && w2.truncated)
        let w3 = ts.windowRows(from, to, 5)
        runner.check("⑨ limit=5（= 总行数）时**不**报截断（边界不多报）",
                     w3.rows.size == 5 && !w3.truncated)
        let w4 = ts.windowRows(now + 10, now + 60, 100)
        runner.check("⑨ 窗口外（from 在未来）取回 0 行", w4.rows.size == 0 && !w4.truncated)

        // ⑩ 分位数边界：空样本回 0（口径里必须与"真的 0ms"区分开 —— 由 total=0 区分）
        let empty: Array<Int64> = []
        runner.check("⑩ 空样本 p50/p95 回 0", triagePercentile(empty, 50) == 0 &&
                     triagePercentile(empty, 95) == 0)
        let one: Array<Int64> = [7]
        runner.check("⑩ 单样本 p50 = p95 = 该值", triagePercentile(one, 50) == 7 &&
                     triagePercentile(one, 95) == 7)
        let two: Array<Int64> = [10, 20]
        runner.check("★★ ⑩ 两样本 p50 = 10、p95 = 20（**最近秩**，不是插值出的 15/19.5）",
                     triagePercentile(two, 50) == 10 && triagePercentile(two, 95) == 20)

        // ⑪ 配置版本号：写入/删除**都要**让版本前进（删除也是改配置）
        let settings = AiSettingsRepo(db)
        runner.check("⑪ 还没写过配置时版本号回 0（**不是** 1 —— 兜底成 1 会与" +
                     "「第一次改配置后」撞号，版本号就白记了；实得 ${settings.revision(now)}）",
                     settings.revision(now) == 0)
        let v0 = settings.revision(now)
        let _p1 = settings.put(SET_AI_TIMEOUT, "31", now)
        let v1 = settings.revision(now)
        runner.check("★ ⑪ 第一项配置写进去 ⇒ 版本号**严格增加**（${v0} -> ${v1}）", v1 > v0)
        let _p2 = settings.put(SET_AI_TIMEOUT, "32", now)
        let v2 = settings.revision(now)
        runner.check("★ ⑪ 连续改两次 ⇒ 版本再增（${v1} -> ${v2}）", v2 > v1)
        /*
         * ★★ 「删掉**最后一项**配置」是这条机制最容易栽的地方（最初的
         *   "整表 +1"写法就栽在这里：表被删空 ⇒ `MAX(revision)` 归 NULL ⇒
         *   版本号**倒退**）。所以这里先确认表里只剩那一项，再删。
         */
        runner.check("⑪ 删之前表里只剩 1 项配置（实得 ${hT7SettingRows(db)} 行）",
                     hT7SettingRows(db) == 1)
        let _r1 = settings.remove(SET_AI_TIMEOUT, now)
        runner.check("⑪ 删之后表里**一项配置都没有**了（保留行不计入；实得 " +
                     "${hT7SettingRows(db)} 行）", hT7SettingRows(db) == 0)
        let v3 = settings.revision(now)
        runner.check("★★ ⑪ 删掉最后一项配置，版本号**仍然前进**（${v2} -> ${v3}）：" +
                     "删除也是一次配置变更，且版本号不寄生在会被删掉的行上", v3 > v2)

        // ⑫ 保留行：接口写不进、删不掉，也不出现在任何回显里
        runner.check("★★ ⑫ 保留行（版本号所在那行）**写不进**：" +
                     "它不在 ai.*/prompt.*/ai.tool.* 命名空间里",
                     !settings.put(SET_AI_REVISION_ROW, "999", now).ok)
        runner.check("★★ ⑫ 保留行**删不掉**", !settings.remove(SET_AI_REVISION_ROW, now))
        runner.check("⑫ 上面两次被拒的调用**没有**动版本号（仍为 ${v3}）",
                     settings.revision(now) == v3)
        let settingsView = aiSettingsJson(settings, now).toString()
        runner.check("★★ ⑫ 保留行不出现在配置回显里（回显按登记清单遍历，" +
                     "不是裸查 KV）", !settingsView.contains(SET_AI_REVISION_ROW))

        // ⑬ 模型标识：有默认模型行 ⇒ 带 id 与**行名**；只有 KV ⇒ id 为 0 但名字仍可见
        let models = AiModelRepo(db)
        settings.attachModels(models)
        let draft = AiModel()
        draft.name = "AC7-排障验证模型"
        draft.kind = "chat"
        draft.provider = "本地"
        draft.baseUrl = "https://ac7.example.com/v1"
        draft.model = "ac7-model"
        draft.temperature = 0.3
        draft.maxTokens = 1024
        draft.keyRef = "env:AC7_KEY"
        draft.enabled = true
        draft.isDefault = true
        let created = models.create(draft, now, 1)
        runner.check("⑬ 造一行默认对话模型", created.ok && created.id > 0)
        let o1 = settings.options(now)
        runner.check("★★ ⑬ 有模型行 ⇒ model_id = 行 id（${o1.modelId}）、model_name = 行名（'${o1.modelName}'）",
                     o1.modelId == created.id && o1.modelName == "AC7-排障验证模型")
        let _rm = models.remove(created.id, now)
        let _kv = settings.put(SET_AI_MODEL, "kv-model-x", now)
        let o2 = settings.options(now)
        runner.check("★★ ⑬ 没有模型行 ⇒ model_id = 0（那是「走 KV」的语义，不是缺省）" +
                     "，但 model_name 仍是**当时真的发出去的**模型名（'${o2.modelName}'）",
                     o2.modelId == 0 && o2.modelName == "kv-model-x")

        /*
         * ⑭ 降级码是**稳定码**（空串 = 真用上了模型），且"是不是降级"只由**两个谓词**回答。
         *   ⚠ 2026-10-16（复核提示项）：原来这一组只断言 `TriageVerdict()` 的结构默认值
         *   （字段是空串/0）—— 那只能说明"结构没变"，说明不了"判据对不对"：
         *   把 `triageDegradeIsFailure` 写成 `return true` 也照样绿。
         *   这里改成**真值表**逐格断言，因为它是整个看板口径的唯一入口。
         */
        let v = TriageVerdict()
        runner.check("★ ⑭ TriageVerdict 默认 degrade_reason 是空串（= 真用上模型），" +
                     "且与给人看的 aiReason 是两个字段",
                     v.aiDegradeReason.size == 0 && v.aiReason.size == 0 && v.aiElapsedMs == 0 &&
                     !v.aiUsedKb && v.aiModelId == 0)
        runner.check("★★ ⑭ 降级谓词真值表：空串不算降级；RED_FLAG 是安全旁路也不算；其余非空码都算失败",
                     !triageDegradeIsFailure("") && !triageDegradeIsFailure("RED_FLAG") &&
                     triageDegradeIsFailure("INVALID_OUTPUT") &&
                     triageDegradeIsFailure("CALL_FAILED") &&
                     triageDegradeIsFailure("AI_DISABLED") &&
                     triageDegradeIsFailure("CONFIG_READ_FAILED") &&
                     /*
                      * ★ 未知码**算失败**（而不是忽略）：将来新增一个降级码时，
                      *   它一定意味着"这次没拿到模型答案"；把它当成功会让
                      *   看板上的 AI 失败率在加字段的那天悄悄变低 —— 静默失真比误报难查得多。
                      *   反过来，唯一被排除的只有 RED_FLAG（规则有意短路，有独立指标）。
                      */
                     triageDegradeIsFailure("SOMETHING_NEW"))
        runner.check("★★ ⑭ 红标旁路谓词真值表：只有 RED_FLAG 为真，且与降级谓词**互斥**",
                     triageDegradeIsRedFlagBypass("RED_FLAG") &&
                     !triageDegradeIsRedFlagBypass("") &&
                     !triageDegradeIsRedFlagBypass("CALL_FAILED") &&
                     !triageDegradeIsRedFlagBypass("AI_DISABLED") &&
                     !(triageDegradeIsFailure("RED_FLAG") &&
                       triageDegradeIsRedFlagBypass("RED_FLAG")))

        /*
         * ⑮ ★★ "降级"与"红标旁路"是**两个**统计量，判据只有一条（走上面的谓词）。
         *   用两行**刻意不一致**的样本钉死（不写库，纯内存聚合）：
         *     · source = "rules" 但 degrade_reason = "RED_FLAG"（规则直接拦红标、没调模型）
         *     · source = "model" 但 degrade_reason = "CALL_FAILED"（模型那次调用失败了）
         *   若判据写成 `source != "model"`，总体 degraded 会得 2 —— 本断言立刻变红；
         *   若把 RED_FLAG 混进 degraded（旧口径），也会得 2 —— 同样变红。
         *   口径分叉的代价：看板上"单行 degraded 之和"与"分组小计"对不上，排障时谁也说不清哪个对。
         */
        let r15a = TriageCallRow()
        r15a.source = "rules"
        r15a.degradeReason = "RED_FLAG"
        r15a.elapsedMs = 10
        let r15b = TriageCallRow()
        r15b.source = "model"
        r15b.degradeReason = "CALL_FAILED"
        r15b.elapsedMs = 20
        let rows15: Array<TriageCallRow> = [r15a, r15b]
        let agg15 = triageStatAggregate(rows15, "source", 20)
        let all15 = agg15[0]
        var sum15: Int64 = 0
        var sum15rf: Int64 = 0
        for (g in agg15[1]) {
            sum15 = sum15 + g.degraded
            sum15rf = sum15rf + g.redFlag
        }
        runner.check("★★ ⑮ degraded 只算模型侧失败（写成 source != model 或把 RED_FLAG 算进去都会得 2），" +
                     "且分组小计 = 总体（实得 degraded=${all15.degraded} 小计 ${sum15}）",
                     all15.total == 2 && all15.degraded == 1 && sum15 == all15.degraded)
        runner.check("★★ ⑮ 红标旁路单独计（实得 redFlag=${all15.redFlag} 小计 ${sum15rf}）—— " +
                     "「AI 失败率」不该把规则正常拦截算进去",
                     all15.redFlag == 1 && sum15rf == all15.redFlag)
        runner.check("★★ ⑮ 总体行的 bucket 是 'all'（空串在 JSON 里与「没算出来」长得一样）",
                     all15.bucket == "all")

        // 收尾：本用例的行不留给后续用例（它们各自会清，但"不留痕"是本仓纪律）
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        db.exec("DELETE FROM ai_model", Array<DbValue>())
        hResetAiSettings(db)
    })
}