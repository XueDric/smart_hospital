package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * ai_builtin.cj —— 内置演示凭据（builtin: 引用）：库里只存引用，密钥本体在代码。
 * 内置密钥只许发往 api.deepseek.com，其它 base_url 一律拒绝出站。
 */

/* 引用前缀，避免各处手写字符串漂移。 */
public let AI_BUILTIN_SCHEME: String = "builtin:"

/* 唯一内置名；新增须同步 aiBuiltinNames()。 */
public let AI_BUILTIN_DEMO: String = "demo"

/* 演示密钥只用于评审窗口，到期（AI_BUILTIN_DEMO_VALID_UNTIL）即拒绝使用。 */
/* 对外发布前必须吊销轮换；禁止写入日志、响应体或错误消息。 */
let AI_BUILTIN_DEMO_KEY: String = "sk-ebd35c9ac7394aa5b7d9847f2a69306d"

public let AI_BUILTIN_DEFAULT_ENDPOINT: String = "https://api.deepseek.com/chat/completions"
public let AI_BUILTIN_DEFAULT_MODEL: String = "deepseek-chat"

public let AI_BUILTIN_DEFAULT_KEY_REF: String = AI_BUILTIN_SCHEME + AI_BUILTIN_DEMO

public func aiBuiltinNames(): Array<String> {
    return [AI_BUILTIN_DEMO]
}

/* builtin:demo → demo；必须整串比对白名单，否则 builtin: 会变成塞任意字符串的口子。 */
public func keyRefBuiltinName(ref: String): ?String {
    let t = ref.trimAscii().toAsciiLower()
    for (n in aiBuiltinNames()) {
        if (t == AI_BUILTIN_SCHEME + n) {
            return Some(n)
        }
    }
    return None
}

/* demo → 密钥本体；返回串禁止入库、写日志或进响应体。 */
public func aiBuiltinKeyOf(name: String): ?String {
    if (name.trimAscii().toAsciiLower() == AI_BUILTIN_DEMO) {
        return Some(AI_BUILTIN_DEMO_KEY)
    }
    return None
}

/* 有效期 YYYY-MM-DD，字典序即时间序；到期后 aiResolveKey() 拒绝使用。 */
public let AI_BUILTIN_DEMO_VALID_UNTIL: String = "2026-12-31"

public func aiBuiltinValidUntil(name: String): String {
    if (name.trimAscii().toAsciiLower() == AI_BUILTIN_DEMO) {
        return AI_BUILTIN_DEMO_VALID_UNTIL
    }
    return ""
}

/* 到期判定；today 为空（时钟取不到/格式坏）不判过期，演示可用性优先。 */
public func aiBuiltinExpired(name: String, today: String): Bool {
    let until = aiBuiltinValidUntil(name)
    if (until.size == 0) {
        return false
    }
    if (today.size == 0) {
        return false
    }
    return today.trimAscii() > until
}

public func aiBuiltinKeyOfAt(name: String, today: String): ?String {
    if (aiBuiltinExpired(name, today)) {
        return None
    }
    return aiBuiltinKeyOf(name)
}

/* 到期原因文案；独立纯函数便于测试断言。 */
public func aiBuiltinExpiredMessage(name: String): String {
    return "内置演示密钥已于 ${aiBuiltinValidUntil(name)} 失效（`builtin:${name}` 只用于评审/演示窗口）" +
           "—— 请换用自己的密钥：`ai.key_ref=env:DEEPSEEK_API_KEY`（或 `file:路径`），" +
           "一条命令的写法见 `tools/set-ai-key.ps1`"
}

public let AI_BUILTIN_ALLOWED_HOST: String = "api.deepseek.com"

/* 该 `keyRef` 是否是内置引用（只认白名单整串）。 */
public func aiKeyRefIsBuiltin(keyRef: String): Bool {
    return keyRefBuiltinName(keyRef).isSome()
}

/* 出站校验 (allowed, reason)；内置密钥发往非白名单主机一律拒绝。 */
public func aiBuiltinKeyHostCheck(keyRef: String, url: String): (Bool, String) {
    if (!aiKeyRefIsBuiltin(keyRef)) {
        return (true, "")
    }
    if (url.toAsciiLower().contains(AI_BUILTIN_ALLOWED_HOST)) {
        return (true, "")
    }
    return (false, "内置密钥（${keyRef}）只允许发往 ${AI_BUILTIN_ALLOWED_HOST}；" +
        "当前 base_url 指向别的服务商，已拒绝发送 —— 请为该模型行单独配置 key_ref，或改用官方端点")
}