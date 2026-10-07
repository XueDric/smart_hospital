package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 写操作的「提议 → 确认」令牌（api-design Part 7.9）
 *
 * 为什么复用 `idem` 表而不是新开一张：
 *   提议需要的正是「一次性 + 按 (kind, actor, token) 定位 + 带时间戳」，
 *   与既有幂等记录同构。两种记录靠 `kind` 区分：
 *     · `ai_prop`  = 提议（payload 有值、used_at 是消费标记）
 *     · 其余       = 既有幂等（payload 恒空、行为完全不变）
 *
 * ⚠ **过期必须自己判**：`IDEM_TTL` 是 24 小时，而确认窗口是 5 分钟。
 *   靠 `idemHit` 的 TTL 会让令牌活一整天 —— 那是安全问题，不是体验问题。
 *
 * ⚠ **锁纪律**：本文件的三个函数都要求调用方**持 `s.lock`**
 *   （与既有幂等记录同处一张表，且 `used_at` 的标记必须与执行同一步完成）。
 */

import std.collection.*
import stdx.encoding.json.*

/* idem 表里的 kind：与既有幂等记录（"task" / "plan"）区分开 */
let AI_PROP_KIND: String = "ai_prop"

/* 确认窗口：5 分钟（见上面那条 ⚠，不能靠 IDEM_TTL） */
public let AI_PROP_TTL: Int64 = 300

/* 令牌前缀：日志与审计里一眼能认出这是提议令牌 */
let AI_PROP_PREFIX: String = "ap_"

/*
 * 审计用的令牌标签：**只取前 8 位**。
 * 日志里不该出现完整令牌 —— 否则能读日志的人就可以拿它去确认。
 */
func aiPropTag(token: String): String {
    let b = token.toArray()
    if (b.size <= 8) {
        return token
    }
    return String.fromUtf8(b[0..8])
}

/*
 * 生成并保存一个提议，返回确认令牌。
 *
 * 令牌用 `newToken()`（= `randHex(32)`，项目既有的令牌源）——
 * **不自己 `Random()`**：评审在 code-review 里提过「`Random()` 加密可预测性未验证」，
 * 而 `newToken()` 是会话令牌在用的那条路径。
 */
public func aiProposalNew(s: Store, actorId: Int64, payload: String, now: Int64): String {
    let token = AI_PROP_PREFIX + newToken()
    let rec = IdemRecord()
    rec.resource_id = 0
    rec.created_at = now
    rec.payload = payload
    rec.used_at = 0
    /* key 里已含 actorId ⇒ 令牌天然绑定到"谁"（G1），别人拿着也用不了 */
    s.idem[idemKey(AI_PROP_KIND, actorId, token)] = rec
    return token
}

/* 取提议（**调用方持锁**）。不属于该 actor 的令牌取不到。 */
public func aiProposalGet(s: Store, actorId: Int64, token: String): ?IdemRecord {
    return s.idem.get(idemKey(AI_PROP_KIND, actorId, token))
}

/*
 * 标记已消费（**调用方持锁**，且必须与"执行"在同一步里完成）——
 * 这样"单次消费"才是原子的：不会有两次确认同时通过 `used_at == 0` 的检查。
 */
public func aiProposalConsume(s: Store, actorId: Int64, token: String,
                              resourceId: Int64, now: Int64): Unit {
    match (s.idem.get(idemKey(AI_PROP_KIND, actorId, token))) {
        case Some(rec) =>
            rec.used_at = now
            rec.resource_id = resourceId
        case None => ()
    }
}
