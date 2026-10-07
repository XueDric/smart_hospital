package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 敏感操作审计日志。
 *
 * api-design §3.5 明确要求：重置密码"该操作记入日志（谁在什么时候重置了谁）——
 * 这是敏感操作，需要可追溯"。
 *
 * 落点：<数据目录>/audit.log，一行一条、制表符分隔，**追加写**。
 * 为什么不用 stdout：进程重启后控制台输出就没了，而这类记录的意义正在于事后追查。
 */

import std.collection.*
import std.fs.*

/*
 * 审计字段的清洗（L-9）。
 *
 * 格式是一行一条、制表符分隔，但 note 里会拼进调用方给的字符串（例如链接 token
 * 直接取自 URL 路径）。未清洗时，一个含换行的 token 就能在日志里**伪造出一整条记录**，
 * 含制表符则能挪动字段边界——事后追查时看到的是攻击者写的内容。
 * 这里在唯一的写入口做替换：CR/LF/TAB 换成空格，同时把控制字符一并挡掉。
 */
func auditSafe(v: String): String {
    let out = ArrayList<UInt8>()
    for (b in v.toArray()) {
        if (b == 13 || b == 10 || b == 9) {
            out.add(UInt8(32))
        } else if (b < 32) {
            out.add(UInt8(63))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/*
 * 记一条审计（**在锁内调用**）：只把这一行挂到 Store 的待写缓冲里，**不做文件 IO**（N-17）。
 *
 * 原先这里直接 `File.appendTo`，而所有调用点都持着 `s.lock` —— 与动作 4 刚确立的
 * "锁内只准备数据、IO 放锁外"口径不一致：同一个提交把 MB 级的整库 IO 挪出了锁，
 * 却把这一处 append 留在了锁里。现在由请求链末端的 flushPending → auditWrite 落盘，
 * 时点仍是"同一个请求内、响应发出之前"，因此"响应 200 ⇒ 审计已落盘"不变。
 *
 * 清洗（L-9）仍在这里做：note 里会拼进链接 token 之类的外部字符串，
 * 含换行就能在日志里**伪造出一整条记录**，含制表符能挪动字段边界。
 */
public func audit(s: Store, actorId: Int64, action: String, targetId: Int64, note: String): Unit {
    let line = "${isoLocal(nowEpoch())}\tactor=${actorId}\t${auditSafe(action)}\ttarget=${targetId}\t${auditSafe(note)}\n"
    s.audit_pending.add(line)
}

/*
 * 把缓冲里的审计行追加落盘（**锁外调用**，由 flushPending 调）。
 * 一次 append 写完一批，既省 open/close，也保证批内顺序与调用顺序一致。
 * 失败只告警：审计日志写不进去，不该让业务操作失败。
 */
public func auditWrite(s: Store, lines: ArrayList<String>): Unit {
    if (lines.size == 0) {
        return
    }
    try {
        if (!exists(s.dir)) {
            Directory.create(s.dir, recursive: true)
        }
        var text = ""
        for (l in lines) {
            text += l
        }
        File.appendTo("${s.dir}/audit.log", text.toArray())
    } catch (e: Exception) {
        println("[WARN] 审计日志写入失败: ${e.message}")
    }
}
