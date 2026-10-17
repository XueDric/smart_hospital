package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== ai_builtin.cj —— 内置演示凭据（`builtin:` 引用）=================
 *
 * 2026-10-17 评审整改：评审指出「默认配置下模型一次都不调」——开箱即用这一项
 * 是零分。用户（项目负责人）决定**把默认模型直接写死在代码里接入**，因此本文件
 * 提供第 4 种密钥引用形式 `builtin:demo`：库里仍然只存**引用**（`builtin:demo`），
 * 密钥本体留在代码里，由 `aiResolveKey()` 在出站那一刻取用。
 *
 * ---------------------------------------------------------------------------
 * ## 为什么是"引用"而不是把密钥写进 `ai_setting` 表
 *
 * `ai_settings.cj` 的设计约束是「库里只存引用、机制性拒绝裸密钥」（见该文件头
 * 注释与 `validateKeyRef()`）。直接往 KV 里塞一把 `sk-...` 会：
 *   · 破坏这条不变量 —— 管理台读取、备份、导出都会把密钥带出去；
 *   · 让"密钥是否已设置"的回显逻辑失去意义（`set=true` 变成"库里有明文"）。
 * ⇒ 新增 `builtin:<名字>` 形式：**名字**进库、**本体**在代码。白名单只有
 *   `builtin:demo` 一个，`validateKeyRef()` 会拒掉其它任何名字。
 *
 * ---------------------------------------------------------------------------
 * ## ⚠⚠ 这把密钥是**真的**，且随源码与二进制一起分发
 *
 * 写死即意味着：
 *   · 任何拿到本仓库或 `hospital-server.exe` 的人都能 `strings` 出它；
 *   · 它一旦被公开（push 到公开远端、随分发包发出、贴进答辩截图）就应视为**已泄露**。
 * ⇒ **对外发布前必须轮换**：在 DeepSeek 控制台吊销这把 key、生成新的，
 *   然后把 `AI_BUILTIN_DEMO_KEY` 换成新值（或干脆把 `builtin:demo` 从白名单去掉，
 *   改回 `env:` / `file:` 的正式做法）。
 * ⚠ 刻意**不做**的程度：不写进日志、不回显在 `/api/ai/settings`（那里只回
 *   `ref_kind=builtin`）、不进错误消息 —— 与 env:/file: 两条路径的纪律一致。
 *
 * ## 公开信息（不是秘密）
 *   · endpoint `https://api.deepseek.com/chat/completions`（OpenAI 兼容）
 *   · model    `deepseek-chat`
 *   · 实测 2026-10-17：curl 该 endpoint 返回 200，`usage.total_tokens` 正常计数。
 */

/* 引用前缀。留成常量，避免各处手写字符串漂移。 */
public let AI_BUILTIN_SCHEME: String = "builtin:"

/* 唯一被接受的内置名字。新增内置凭据必须同时加进 `aiBuiltinNames()`。 */
public let AI_BUILTIN_DEMO: String = "demo"

/*
 * ★ 内置演示密钥本体。
 *
 * ⚠ 只有 `aiResolveKey()` 该读它；其它任何地方需要密钥都应先拿到"引用"再解析。
 * ⚠ 不要在这行前后加"打印/校验"性质的调试代码 —— 一行 `println` 就会把密钥
 *   写进日志与答辩录屏。
 */
let AI_BUILTIN_DEMO_KEY: String = "sk-ebd35c9ac7394aa5b7d9847f2a69306d"

/* 与内置凭据配套的默认 endpoint / 模型名（`aiSettingSpecs()` 的默认值取自这里）。 */
public let AI_BUILTIN_DEFAULT_ENDPOINT: String = "https://api.deepseek.com/chat/completions"
public let AI_BUILTIN_DEFAULT_MODEL: String = "deepseek-chat"

/* 默认引用：开箱即用 —— 新建库/未改过配置时 `ai.key_ref` 就是它。 */
public let AI_BUILTIN_DEFAULT_KEY_REF: String = AI_BUILTIN_SCHEME + AI_BUILTIN_DEMO

/* 白名单（`validateKeyRef()` 与 `/api/ai/settings` 的提示共用）。 */
public func aiBuiltinNames(): Array<String> {
    return [AI_BUILTIN_DEMO]
}

/*
 * `builtin:demo` → `demo`；不是 `builtin:` 开头或名字不在白名单 → None。
 *
 * ⚠ 必须比对**白名单**而不是"非空即可" —— 否则 `builtin:` 会变成一个能塞任意
 *   字符串的口子（`builtin:sk-xxx` 就又能把密钥存进库了，正是要防的那件事）。
 */
public func keyRefBuiltinName(ref: String): ?String {
    let t = ref.trimAscii().toAsciiLower()
    /* 整串比对白名单（不做前缀切片）：`builtin:` 后面只允许白名单里的名字。 */
    for (n in aiBuiltinNames()) {
        if (t == AI_BUILTIN_SCHEME + n) {
            return Some(n)
        }
    }
    return None
}

/*
 * `demo` → 密钥本体。名字不在白名单 ⇒ None（调用方按"解析不到"处理）。
 *
 * ⚠ 返回的字符串**不得**被存进任何字段、日志、响应体（同 `aiResolveKey` 的纪律）。
 */
public func aiBuiltinKeyOf(name: String): ?String {
    if (name.trimAscii().toAsciiLower() == AI_BUILTIN_DEMO) {
        return Some(AI_BUILTIN_DEMO_KEY)
    }
    return None
}
