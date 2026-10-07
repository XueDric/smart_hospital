package spike

/*
 * std.sync.Semaphore 实测探针（cjc 1.2.0）
 *
 * 目的：llm-client-spec §5 P3 要求「用信号量强制 maxConcurrent」，
 * 但 Cangjie 的 Semaphore 语义（默认 amount、count 语义、tryAcquire 是否非阻塞）
 * 必须先验明，否则并发上限会写成摆设。
 *
 * 从 std.sync.cjo 提取到的符号（1.2.0）：
 *   std.sync9SemaphoreC6<init>Fl$$                       -> Semaphore(count: Int64)
 *   std.sync9SemaphoreC5countP                           -> 只读属性 count
 *   std.sync9SemaphoreC7acquireFl!6amount=$$u            -> acquire(amount!: Int64): Unit
 *   std.sync9SemaphoreC7releaseFl!6amount=$$u            -> release(amount!: Int64): Unit
 *   std.sync9SemaphoreC10tryAcquireFl!6amount=$$b        -> tryAcquire(amount!: Int64): Bool
 *   （`!` = 有默认值，故 acquire() 可不带参）
 */

import std.sync.*
import std.time.*

func nowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/* 取一次许可 -> 占住 holdMs -> 还回去 */
func worker(sem: Semaphore, holdMs: Int64): Unit {
    sem.acquire()
    sleep(Duration.millisecond * holdMs)
    sem.release()
}

main(): Int64 {
    println("=== std.sync.Semaphore 实测（cjc 1.2.0）===")

    // T1 构造函数 + count 语义
    let s0 = Semaphore(3)
    println("  [T1] Semaphore(3).count = ${s0.count}   （期望 3）")

    // T2 并发上限：上限 2，4 个 worker 各持 300ms
    //    串行(1)      ≈ 1200ms
    //    限流(2)      ≈  600ms   <- 正确
    //    没限住(4)    ≈  300ms
    let sem = Semaphore(2)
    let t0 = nowMs()
    let f1 = spawn { worker(sem, 300) }
    let f2 = spawn { worker(sem, 300) }
    let f3 = spawn { worker(sem, 300) }
    let f4 = spawn { worker(sem, 300) }
    f1.get()
    f2.get()
    f3.get()
    f4.get()
    let ms = nowMs() - t0
    println("  [T2] 上限=2 / 4×300ms -> 实测 ${ms}ms")
    if (ms >= 500 && ms < 900) {
        println("       => 限流生效（两批）")
    } else if (ms < 500) {
        println("       => 没限住！信号量没起作用")
    } else {
        println("       => 退化成串行，需复核")
    }

    // T3 tryAcquire 是否非阻塞（已取满时应立刻返回 false，而不是等）
    let s1 = Semaphore(1)
    s1.acquire()
    let t1 = nowMs()
    let got = s1.tryAcquire()
    let tryMs = nowMs() - t1
    println("  [T3] Semaphore(1) 取满后 tryAcquire() = ${got}（期望 false），耗时 ${tryMs}ms（期望 ~0ms 非阻塞）")
    s1.release()
    let got2 = s1.tryAcquire()
    println("  [T3] release() 之后 tryAcquire() = ${got2}（期望 true）")
    s1.release()

    // T4 批量 acquire/release（⚠ amount 是具名参数，不能位置传参）
    let s2 = Semaphore(4)
    s2.acquire(amount: 3)
    println("  [T4] Semaphore(4).acquire(amount: 3) 后 count = ${s2.count}（期望 1）")
    s2.release(amount: 3)
    println("  [T4] release(amount: 3) 后 count = ${s2.count}（期望 4）")

    // T5 上限=1 的极端：应当完全串行
    let s3 = Semaphore(1)
    let t2 = nowMs()
    let g1 = spawn { worker(s3, 200) }
    let g2 = spawn { worker(s3, 200) }
    let g3 = spawn { worker(s3, 200) }
    g1.get()
    g2.get()
    g3.get()
    println("  [T5] 上限=1 / 3×200ms -> 实测 ${nowMs() - t2}ms（期望 ≈600ms）")

    println("")
    println("Semaphore 探针结束")
    return 0
}
