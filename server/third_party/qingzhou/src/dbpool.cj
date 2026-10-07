package qingzhou

import std.collection.*
import std.sync.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 数据库连接池（DbPool 接口 + SimpleDbPool 实现）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 为什么需要连接池：
 *   业务侧（如 admin 示例）长期持有单个 RbacStore（单 DbBackend 连接），
 *   并发请求共享同一连接。这在两种场景下不安全：
 *     1) 底层驱动非线程安全：多个协程/线程同时 query/exec 可能数据竞争；
 *     2) 事务串线：withTransaction 的 begin/commit 在共享连接上并发交错，
 *        请求 A 的 begin 会被请求 B 的 commit 提前关闭。
 *   连接池把「连接」抽象为可借可还的资源：每个请求（或事务）borrow 一条
 *   独占连接，用完 release 归还，池负责复用与并发隔离。
 *
 * 设计要点（对齐 DbBackend 的既有风格）：
 *   - DbPool 只暴露 acquire/release/close/idleCount 四件事，最小能力集；
 *   - SimpleDbPool 用 std.sync.Mutex 保护空闲队列，线程安全；
 *   - 空闲连接用 ArrayList 做栈（LIFO）复用：归还时压栈、借出时弹栈，
 *     保证「最近归还的连接最热」；
 *   - 工厂函数创建新连接，池不感知具体后端（CangDB/MySQL/未来后端均可）。
 *
 * 本文件无外部依赖，进默认编译集（与 db.cj 一致）。
 */

/*
 * 连接池抽象接口：业务侧依赖此接口，不感知具体池实现。
 */
public interface DbPool {
    /* 借出一条空闲连接；池为空时通过工厂新建一条。 */
    func acquire(): DbBackend

    /* 归还一条连接，压回空闲栈供后续复用。 */
    func release(backend: DbBackend): Unit

    /* 关闭池：逐个关闭空闲连接，释放底层资源（进程退出前调用）。 */
    func close(): Unit

    /* 当前空闲连接数（可观测性：监控/诊断用）。 */
    func idleCount(): Int64
}

/*
 * 简单连接池实现：基于互斥锁 + 空闲栈（LIFO）的线程安全连接池。
 *
 * 语义：
 *   - acquire：空闲栈非空则弹栈复用；为空则调 factory 新建。新建连接数
 *     不受 capacity 硬限制（capacity 仅限制「空闲」连接的保有量，见下）；
 *   - release：把连接压回栈；若栈已满（>= capacity）则直接关闭该连接，
 *     避免空闲连接无限堆积（capacity 是「空闲保有上限」，非并发硬上限）；
 *   - close：关闭所有空闲连接。已借出（in-flight）的连接不在此处关闭，
 *     由调用方归还或自行关闭（简单语义，避免 double-close）。
 *
 * 线程安全：所有对空闲栈的读写都在互斥锁内完成。
 */
public class SimpleDbPool <: DbPool {
    private let factory: () -> DbBackend
    private let capacity: Int64
    private let mutex: Mutex
    private let idle: ArrayList<DbBackend>

    public init(factory: () -> DbBackend, capacity: Int64) {
        this.factory = factory
        // capacity 至少 1，避免退化成语义歧义（0 表示「不保留空闲连接」，
        // 每次 release 都立即关闭，等价于无池——保留此语义但至少允许 1）。
        this.capacity = if (capacity < 1) { 1 } else { capacity }
        this.mutex = Mutex()
        this.idle = ArrayList<DbBackend>()
    }

    /* 借出一条连接：优先复用空闲栈顶（LIFO），栈空则新建。 */
    public func acquire(): DbBackend {
        var reused: ?DbBackend = None
        mutex.lock()
        if (idle.size > 0) {
            let lastIdx = idle.size - 1
            reused = idle.get(lastIdx)
            idle.remove(lastIdx..=lastIdx)
        }
        mutex.unlock()
        match (reused) {
            case Some(backend) => return backend
            case None => return factory()
        }
    }

    /* 归还连接：栈未满压栈复用，栈满则直接关闭（避免空闲无限堆积）。 */
    public func release(backend: DbBackend): Unit {
        mutex.lock()
        let shouldKeep = idle.size < capacity
        if (shouldKeep) {
            idle.add(backend)
        }
        mutex.unlock()
        if (!shouldKeep) {
            // 栈已满，这条连接不再保留，直接关闭
            backend.close()
        }
    }

    /* 关闭池：关闭全部空闲连接。已借出的连接由调用方负责关闭/归还。 */
    public func close(): Unit {
        mutex.lock()
        let toClose = ArrayList<DbBackend>()
        for (b in idle) {
            toClose.add(b)
        }
        idle.clear()
        mutex.unlock()
        for (b in toClose) {
            b.close()
        }
    }

    /* 当前空闲连接数（供诊断/监控）。 */
    public func idleCount(): Int64 {
        mutex.lock()
        let n = idle.size
        mutex.unlock()
        return n
    }
}
