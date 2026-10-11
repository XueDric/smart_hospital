package qingzhou

import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 通用熔断器（Circuit Breaker）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 保护出站调用（下游服务 / 数据库 / 外部 API）：连续失败达到阈值后
 * 「打开」熔断，快速失败而不再真实调用；冷却时间过后进入「半开」，
 * 放行一个试探请求——成功则闭合，失败则重新打开。
 *
 * 状态机：
 *   Closed --(连续失败 maxFailures 次)--> Open
 *   Open   --(冷却 cooldownSeconds 秒)--> HalfOpen
 *   HalfOpen --(试探成功)--> Closed
 *   HalfOpen --(试探失败)--> Open
 *
 * 用法：
 *   let cb = CircuitBreaker(5, 30)     // 连续 5 次失败打开，冷却 30 秒
 *   if (!cb.isAllowed()) { return 降级结果 }
 *   try { 调用下游 } catch { cb.onFailure(); ... }
 *   cb.onSuccess()
 */

/* 熔断器状态（用常量避免 enum 默认无 == 的麻烦）。 */
let CB_CLOSED: Int64 = 0
let CB_OPEN: Int64 = 1
let CB_HALF_OPEN: Int64 = 2

public class CircuitBreaker {
    private let maxFailures: Int64
    private let cooldownSeconds: Int64
    private var failureCount: Int64 = 0
    private var openedAt: Int64 = 0
    private var state: Int64 = CB_CLOSED

    public init(maxFailures: Int64, cooldownSeconds: Int64) {
        this.maxFailures = maxFailures
        this.cooldownSeconds = cooldownSeconds
    }

    /*
     * 是否允许发起真实调用。
     *   Closed / HalfOpen -> true
     *   Open 且冷却未到 -> false
     *   Open 且冷却已到 -> 转 HalfOpen，返回 true（放行一个试探请求）
     */
    public func isAllowed(): Bool {
        if (state == CB_OPEN) {
            let now = DateTime.nowUTC().toUnixTimeStamp().toSeconds()
            if (now - openedAt >= cooldownSeconds) {
                state = CB_HALF_OPEN
                return true
            }
            return false
        }
        return true
    }

    /* 调用成功：闭合熔断，重置失败计数。 */
    public func onSuccess(): Unit {
        failureCount = 0
        state = CB_CLOSED
    }

    /* 调用失败：计数；达到阈值或半开试探失败时打开熔断。 */
    public func onFailure(): Unit {
        let now = DateTime.nowUTC().toUnixTimeStamp().toSeconds()
        if (state == CB_HALF_OPEN) {
            // 半开试探失败 -> 重新打开
            state = CB_OPEN
            openedAt = now
            failureCount = 0
        } else {
            failureCount += 1
            if (failureCount >= maxFailures) {
                state = CB_OPEN
                openedAt = now
                failureCount = 0
            }
        }
    }

    /* 当前状态名（"closed"/"open"/"half-open"），调试与测试用。 */
    public func stateName(): String {
        if (state == CB_OPEN) {
            return "open"
        }
        if (state == CB_HALF_OPEN) {
            return "half-open"
        }
        return "closed"
    }
}
