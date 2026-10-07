/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+183 / -2（git log --author 统计；标注日期 2026-09-18）
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 单测：main.exe test
 *
 * 只测**纯逻辑**（时间、口令、权限、落盘）——它们能脱离 HTTP 运行，
 * 也正是最容易错、错了最难发现的部分。接口层的行为由
 * tests/smoke.ps1 打真实 HTTP 覆盖（集成证据）。
 *
 * 时间用**独立实现算出的锚点**对拍：锚点由 .NET DateTimeOffset 生成，
 * 与本项目代码无任何共享逻辑，因此能真正发现历法算错。
 */

import std.collection.*
import std.fs.*
import stdx.encoding.hex.*
import stdx.encoding.json.*

class TR {
    public var pass: Int64 = 0
    public var fail: Int64 = 0

    public init() {}

    public func ok(name: String, cond: Bool): Unit {
        if (cond) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}")
        }
    }

    public func eqs(name: String, got: String, want: String): Unit {
        if (got == want) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}\n       got  [${got}]\n       want [${want}]")
        }
    }

    public func eqi(name: String, got: Int64, want: Int64): Unit {
        if (got == want) {
            pass += 1
        } else {
            fail += 1
            println("  FAIL ${name}\n       got  ${got}\n       want ${want}")
        }
    }
}

/* ===================== 时间 ===================== */

func testTime(t: TR): Unit {
    println("- timex 时间与时区")
    /* 锚点：由 .NET DateTimeOffset 独立算出（+08:00 口径） */
    t.eqs("isoLocal(0)", isoLocal(0), "1970-01-01T08:00:00+08:00")
    t.eqs("isoLocal(1e9)", isoLocal(1000000000), "2001-09-09T09:46:40+08:00")
    t.eqs("isoLocal(闰日)", isoLocal(1709179200), "2024-02-29T12:00:00+08:00")
    t.eqs("isoLocal(2026元旦)", isoLocal(1767196800), "2026-01-01T00:00:00+08:00")
    t.eqs("isoUtc(2e9)", isoUtc(2000000000), "2033-05-18T03:33:20Z")

    t.eqi("parseIso(+08:00)", parseIso("2026-09-20T18:00:00+08:00") ?? -1, 1789898400)
    t.eqi("parseIso(Z)", parseIso("2001-09-09T01:46:40Z") ?? -1, 1000000000)
    t.eqi("parseIso(无偏移=+08)", parseIso("2026-09-20T18:00:00") ?? -1, 1789898400)
    t.eqi("parseIso(空格分隔)", parseIso("2026-09-20 18:00:00") ?? -1, 1789898400)
    t.eqi("parseIso(仅日期)", parseIso("2026-09-20") ?? -1, 1789833600)
    t.eqi("parseIso(+00:00 = 同一时刻)", parseIso("2026-09-20T10:00:00+00:00") ?? -1, 1789898400)
    t.eqi("parseIso(负偏移 -08:00)", parseIso("2026-09-20T00:00:00-08:00") ?? -1, 1789891200)
    t.eqi("parseIso(+08:00 同日更早)", parseIso("2026-09-20T02:00:00+08:00") ?? -1, 1789840800)
    t.ok("parseIso(斜杠)=None", parseIso("2026/09/20").isNone())
    t.ok("parseIso(空)=None", parseIso("").isNone())
    t.ok("parseIso(乱)=None", parseIso("不是时间").isNone())
    t.ok("parseIso(月越界)=None", parseIso("2026-13-01T00:00:00+08:00").isNone())

    /* P1 M-6：ArkTS/JS 的 toISOString() 带毫秒，必须收 */
    t.eqi("parseIso(小数秒 .307Z)", parseIso("2026-09-20T10:00:00.307Z") ?? -1, 1789898400)
    t.eqi("parseIso(小数秒 +08:00)", parseIso("2026-09-20T18:00:00.5+08:00") ?? -1, 1789898400)
    t.eqi("parseIso(小数秒 无偏移)", parseIso("2026-09-20T18:00:00.123456") ?? -1, 1789898400)
    t.ok("parseIso(只有点没数字)=None", parseIso("2026-09-20T18:00:00.Z").isNone())
    /* P2 L-5：历法上不存在的日期必须拒绝，不能静默顺延 */
    t.ok("parseIso(2月30日)=None", parseIso("2026-02-30T00:00:00+08:00").isNone())
    t.ok("parseIso(平年2月29日)=None", parseIso("2026-02-29T00:00:00+08:00").isNone())
    t.eqi("parseIso(闰年2月29日) 有效", parseIso("2024-02-29T12:00:00+08:00") ?? -1, 1709179200)
    t.ok("parseIso(4月31日)=None", parseIso("2026-04-31T00:00:00+08:00").isNone())
    t.ok("parseIso(0日)=None", parseIso("2026-04-00T00:00:00+08:00").isNone())

    t.eqi("startOfLocalDay", startOfLocalDay(1789898400), 1789833600)
    t.eqi("startOfLocalDay(0)", startOfLocalDay(0), -28800)

    t.ok("逾期", isOverdue(100, 200))
    t.ok("无截止不算逾期", !isOverdue(0, 200))
    t.ok("未到期不算逾期", !isOverdue(300, 200))

    /* 400 天连续往返：历法算错会在某一天暴露 */
    var i: Int64 = 1600000000
    var good = true
    while (i < 1600000000 + 400 * 86400) {
        match (parseIso(isoLocal(i))) {
            case Some(x) =>
                if (x != i) {
                    good = false
                }
            case None => good = false
        }
        i += 86400 + 137
    }
    t.ok("400 天 ISO 往返", good)
}

/* ===================== 字符串 ===================== */

func testStr(t: TR): Unit {
    println("- strx 字符串与手机号")
    t.ok("startsWith", startsWithAscii("Bearer abc", "Bearer "))
    t.ok("startsWith 否", !startsWithAscii("bearer", "Bearer "))
    t.ok("contains", containsAscii("addr=127.0.0.1:5000", "127.0.0.1"))
    t.ok("contains 否", !containsAscii("addr=10.0.0.1", "127.0.0.1"))
    t.eqs("subFrom", subFrom("Bearer abc", 7), "abc")
    t.ok("isBlank", isBlank("   "))
    t.ok("非 blank", !isBlank(" x "))
    t.ok("phone 合法", isPhone("13800000000"))
    t.ok("phone 位数", !isPhone("1380000000"))
    t.ok("phone 首位", !isPhone("23800000000"))
    t.ok("phone 非数字", !isPhone("1380000000a"))
    t.ok("phone 空", !isPhone(""))

    /* L-6：定时安全比较 —— 语义必须与 == 一致，且长度不同也不能误判为相等 */
    t.ok("constantTimeEq 相等", constantTimeEq("ABC123", "ABC123"))
    t.ok("constantTimeEq 末位不同", !constantTimeEq("ABC123", "ABC124"))
    t.ok("constantTimeEq 首位不同", !constantTimeEq("ABC123", "XBC123"))
    t.ok("constantTimeEq 长度不同", !constantTimeEq("ABC123", "ABC1234"))
    t.ok("constantTimeEq 空串相等", constantTimeEq("", ""))
    t.ok("constantTimeEq 空与非空", !constantTimeEq("", "a"))
    t.ok("constantTimeEq 中文", constantTimeEq("社团口令", "社团口令"))
    t.ok("constantTimeEq 中文不同", !constantTimeEq("社团口令", "社团口另"))
}

/* ===================== 随机 ===================== */

func testIds(t: TR): Unit {
    println("- ids 随机与口令")
    t.eqi("token 长度", newToken().size, 64)
    t.ok("token 唯一", newToken() != newToken())
    t.eqi("注册口令长度", newRegisterCode().size, 6)
    t.eqi("临时密码长度", newTempPassword().size, 8)
    /*
     * D-6（2026-09-16 定稿）：密码 = **8–32 字节** 且 **只用数字 / 英文 / 符号**。
     * 这三组断言是口径的回归闸门：
     *   · 去掉上限 → "33 位"那条变红
     *   · 去掉字符集 → "中文"与"含空格"两条变红
     *   · 改回 6 位下限 → "7 位"那条变红
     */
    t.eqs("密码 8 位 ASCII 合法（下界）", passwordError("abc12345"), "")
    /* 32 位 = randHex(16)（十六进制串长度是字节数的 2 倍），33 位再多一个字符 */
    t.eqs("密码 32 位 ASCII 合法（上界）", passwordError(randHex(16)), "")
    t.ok("密码 7 位 → 拒（下界）", passwordError("abc1234").size > 0)
    t.ok("密码 33 位 → 拒（上界，原先没有上限）", passwordError("a" + randHex(16)).size > 0)
    t.ok("密码含中文 → 拒（字符集；18 字节本来在长度区间内）", passwordError("密码密码密码").size > 0)
    t.ok("密码含空格 → 拒（不可见字符）", passwordError("abc 1234").size > 0)
    t.ok("密码含全角字符 → 拒（字符集）", passwordError("ａｂｃ12345").size > 0)
    t.eqs("密码含符号 ._/\\-! 合法", passwordError("Abc123._/\\-!"), "")
    /* 「密码1」= 3 个中文字节 + 1 位数字 = 7 字节 → 应该报**长度**错，不是字符集错 */
    t.ok("长度先判：7 字节中文报长度错", containsAscii(passwordError("密码1"), "至少"))
    /* 重置密码签发的临时密码必须落在自己的口径内，否则管理员一重置就登不上 */
    t.eqs("临时密码符合密码口径（D-6）", passwordError(newTempPassword()), "")
    let alpha = CODE_ALPHABET
    var i: Int64 = 0
    var allIn = true
    while (i < 50) {
        let c = randCode(8)
        var j: Int64 = 0
        let cb = c.toArray()
        while (j < cb.size) {
            if (!containsAscii(alpha, String.fromUtf8(Array<UInt8>(1, repeat: cb[j])))) {
                allIn = false
            }
            j += 1
        }
        i += 1
    }
    t.ok("口令字母表不越界", allIn)
    var k: Int64 = 0
    var inRange = true
    while (k < 200) {
        let r = randBelow(10)
        if (r < 0 || r >= 10) {
            inRange = false
        }
        k += 1
    }
    t.ok("randBelow 范围", inRange)
    t.eqi("randBelow(1)", randBelow(1), 0)
}

/* ===================== 口令 ===================== */

func testPassword(t: TR): Unit {
    println("- auth 口令哈希")
    /* RFC 7914 §11 的 PBKDF2-HMAC-SHA256 公开测试向量 */
    let v1 = toHexString(pbkdf2Sha256("passwd".toArray(), "salt".toArray(), 1, 64))
    t.eqs("RFC7914 向量1", v1, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    let v2 = toHexString(pbkdf2Sha256("Password".toArray(), "NaCl".toArray(), 80000, 64))
    t.eqs("RFC7914 向量2", v2, "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    /* 正式参数（100k）与 .NET Rfc2898DeriveBytes 对拍 */
    let v3 = toHexString(pbkdf2Sha256("password".toArray(), "saltSALT".toArray(), 100000, 32))
    t.eqs("100k 对拍 .NET", v3, "5c809e359c03e25b885cf90db237fdea07be535f27a2d4064ae719b6f2996aaa")

    let rec = newPasswordRecord("abc12345")
    t.ok("正确口令通过", verifyPw("abc12345", rec[0], rec[1], rec[2]))
    t.ok("错误口令拒绝", !verifyPw("abc12346", rec[0], rec[1], rec[2]))
    t.ok("空盐拒绝", !verifyPw("abc12345", "", rec[1], rec[2]))
    t.ok("迭代为0拒绝", !verifyPw("abc12345", rec[0], rec[1], 0))
    t.eqi("迭代次数", rec[2], PBKDF2_ITER)
    /* 同一口令两次的盐必须不同 */
    let rec2 = newPasswordRecord("abc12345")
    t.ok("盐随机", rec[0] != rec2[0])
}

/* ===================== 落盘 ===================== */

func testStore(t: TR): Unit {
    println("- store 落盘与加载")
    let dir = "build/test-data"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    /*
     * 派生目录也必须清（2026-09-16 修）。
     *
     * 下面的 M-7 / N-5 / 空 token 三块都是同一个套路：先建库 → **往 db.json 写坏数据** →
     * 断言 storeLoad 拒绝启动。坏数据是**故意留在磁盘上**的（这块测试的产物），
     * 于是**不重新编译就连跑两次单测，第二次会在这个目录上先 `storeLoad` 直接抛异常**，
     * 整个测试进程崩掉 —— 报出来的还是"数据文件损坏"，看着像真 bug。
     * 违反的正是项目自己的测试标准："isolated setup/teardown；不依赖外部状态"。
     * （之前一直没暴露：跑测试前若执行过 `build.ps1`，它会重建 build/ 顺带清掉这些目录。）
     */
    for (d in ["build/test-data-m7", "build/test-data-n5", "build/test-data-linkkey"]) {
        if (exists(d)) {
            remove(d, recursive: true)
        }
    }
    let s = Store(dir)

    let d = Department()
    d.id = 1
    d.name = "课题部"
    d.sort = 1
    s.departments[1] = d

    let m = Member()
    m.id = 1
    m.name = "张三"
    m.phone = "13800000000"
    m.pw_salt = "aa"
    m.pw_hash = "bb"
    m.pw_iter = 100000
    m.role = "member"
    m.dept_id = 1
    m.status = "active"
    m.joined_at = 1789898400
    s.members[1] = m
    s.next_member = 2

    let p = Plan()
    p.id = 1
    p.title = "2026 招新"
    p.owner_id = 1
    p.dept_id = 1
    p.created_at = 1789898400
    s.plans[1] = p

    let x = Task()
    x.id = 1
    x.title = "联系场地"
    x.desc = "需确认容纳人数"
    x.owner_id = 1
    x.plan_id = 1
    x.dept_id = 1
    x.status = "doing"
    x.due_at = 1789898400
    x.created_by = 1
    x.created_at = 1789898400
    x.updated_at = 1789898400
    s.tasks[1] = x

    let tok = TokenRecord()
    tok.member_id = 1
    tok.created_at = 1789898400
    tok.expires_at = 1789898400 + 100
    s.tokens["abc"] = tok
    s.register_code = "K3M9P2"
    s.register_code_by = 1

    storeSaveNow(s)

    t.ok("db.json 已生成", exists(s.dbFile()))
    t.ok("tmp 已清理", !exists(s.dbFile() + ".tmp"))

    let l = storeLoad(dir)
    t.eqi("成员数", l.members.size, 1)
    t.eqi("部门数", l.departments.size, 1)
    match (l.members.get(1)) {
        case Some(mm) =>
            t.eqs("中文姓名往返", mm.name, "张三")
            t.eqs("手机号往返", mm.phone, "13800000000")
            t.eqi("口令迭代往返", mm.pw_iter, 100000)
            t.eqi("部门往返", mm.dept_id, 1)
        case None => t.ok("成员 1 存在", false)
    }
    match (l.plans.get(1)) {
        case Some(pp) => t.eqs("课题标题往返", pp.title, "2026 招新")
        case None => t.ok("课题 1 存在", false)
    }
    match (l.tasks.get(1)) {
        case Some(tt) =>
            t.eqs("任务状态往返", tt.status, "doing")
            t.eqs("任务描述中文往返", tt.desc, "需确认容纳人数")
        case None => t.ok("任务 1 存在", false)
    }
    match (l.departments.get(1)) {
        case Some(dd) => t.eqs("部门名往返", dd.name, "课题部")
        case None => t.ok("部门 1 存在", false)
    }
    match (l.tokens.get("abc")) {
        case Some(tr) => t.eqi("令牌成员往返", tr.member_id, 1)
        case None => t.ok("令牌存在", false)
    }
    t.eqs("注册口令往返", l.register_code, "K3M9P2")
    t.eqi("next_member 往返", l.next_member, 2)

    /*
     * D-4（2026-09-16）：Task 新增 `help_dept_id` / `help_member_id` 之后，
     * **旧库（没有这两个字段的 db.json）必须照常加载** —— 这是文档里那句
     * 「旧库无需迁移」的回归闸门。这里手写一个只含老字段的最小库文件。
     * （Directory.create 在目录已存在时照样抛异常，所以先判存在 —— 见 writeDbFile 的注释。）
     */
    let oldDir = "build/test-data-store-old"
    if (!exists(oldDir)) {
        Directory.create(oldDir, recursive: true)
    }
    let oldJson = "{\"next_task\":3,\"tasks\":[{\"id\":2,\"title\":\"老任务\",\"owner_id\":1," +
        "\"status\":\"blocked\",\"blocker\":\"老的阻塞原因\",\"created_at\":1789898400}]}"
    File.writeTo(oldDir + "/db.json", oldJson.toArray())
    let old = storeLoad(oldDir)
    t.eqi("旧库能加载（D-4 无需迁移）", old.tasks.size, 1)
    match (old.tasks.get(2)) {
        case Some(ot) =>
            t.eqs("旧任务标题", ot.title, "老任务")
            t.eqs("旧任务状态", ot.status, "blocked")
            t.eqi("旧任务 help_dept_id 默认 0（D-4）", ot.help_dept_id, 0)
            t.eqi("旧任务 help_member_id 默认 0（D-4）", ot.help_member_id, 0)
            t.ok("旧任务无求助对象 → needs_help=null（D-4）",
                containsAscii(taskBrief(old, ot, 1789898400).toString(), "\"needs_help\":null"))
        case None => t.ok("旧任务存在", false)
    }

    /* 备份文件：**第二次保存**时才会生成（第一次没有旧库可备份） */
    storeSaveNow(s)
    t.ok("bak 已生成（第二次保存）", exists(s.dbFile() + ".bak"))

    /* 坏库：必须报错，绝不静默降级为空库（否则下次保存会覆盖真实数据） */
    File.writeTo(s.dbFile(), "{ not json".toArray())
    var threw = false
    try {
        storeLoad(dir)
    } catch (e: Exception) {
        threw = true
    }
    t.ok("坏库必须报错", threw)

    /* 当前格式带 version 时，缺少整张表也必须拒绝启动，不能被当成空表覆盖。 */
    let missingTable = "{\"version\":1,\"departments\":[],\"members\":[],\"plans\":[]}"
    File.writeTo(s.dbFile(), missingTable.toArray())
    var threwMissingTable = false
    try {
        storeLoad(dir)
    } catch (e: Exception) {
        threwMissingTable = true
    }
    t.ok("当前格式缺少整表必须报错", threwMissingTable)

    /*
     * P1 M-7：**单条记录**坏掉也必须报错。
     * 原先每个元素的解析异常都被 catch 吞掉：文件里 2 个部门坏 1 个，
     * 服务照常启动，用户看到 1 个；下一次保存就把那 1 条永久覆盖。
     * 这里手写一个"数组里混了一个字符串"的库，要求 storeLoad 直接拒绝启动。
     */
    let good = storeLoad(dir + "-m7")
    storeSaveNow(good) /* 先建出目录，再用坏内容覆盖 db.json */
    let badJson = "{\"version\":1,\"departments\":[\"这不是一个部门对象\",{\"id\":1,\"name\":\"课题部\",\"sort\":0}],\"members\":[]}"
    File.writeTo(good.dbFile(), badJson.toArray())
    var threw2 = false
    try {
        storeLoad(dir + "-m7")
    } catch (e: Exception) {
        threw2 = true
    }
    t.ok("单条坏记录必须报错（M-7）", threw2)

    /*
     * N-5：idem 也要走 checkLoaded —— 它原先漏了，是 8 张表里唯一的例外。
     * 影响确实最小（24 小时 TTL 的幂等映射，丢一条最坏是客户端重试时多建一个资源），
     * 但"例外只存在于代码里"正是后人最容易踩的坑，所以把口径统一成一种。
     */
    let idemDir = dir + "-n5"
    let goodIdem = storeLoad(idemDir)
    storeSaveNow(goodIdem) /* 先建出目录，再用坏内容覆盖 db.json */
    let badIdem = "{\"version\":1,\"departments\":[],\"members\":[],\"idem\":[\"这不是一个幂等记录\"]}"
    File.writeTo(goodIdem.dbFile(), badIdem.toArray())
    var threw3 = false
    try {
        storeLoad(idemDir)
    } catch (e: Exception) {
        threw3 = true
    }
    t.ok("idem 坏记录也必须报错（N-5）", threw3)

    /*
     * 2026-09-16（读码发现的一致性缺口）：**空 token 的招募链接记录也必须报错**。
     *
     * 三张以字符串为主键的表里，tokens / idem 都会跳过空键（于是数组条数 ≠ map 条数，
     * `checkLoaded` 按既定口径拒绝启动），只有 `invite_links` 原先无条件 `m[token] = x` ——
     * 空 token 被塞进 `""` 键，两条计数相等，**一条损坏记录被静默接受**
     * （还能被 `GET /api/v1/join/` 命中）。
     * 这条断言就是那个缺口的闸门：改回去（取消 size > 0 判断）它立刻变红。
     */
    let linkDir = dir + "-linkkey"
    let goodLink = storeLoad(linkDir)
    storeSaveNow(goodLink) /* 先建出目录，再用坏内容覆盖 db.json */
    let badLink = "{\"version\":1,\"invite_links\":[{\"token\":\"\",\"dept_id\":1,\"enabled\":true}]}"
    File.writeTo(goodLink.dbFile(), badLink.toArray())
    var threw4 = false
    try {
        storeLoad(linkDir)
    } catch (e: Exception) {
        threw4 = true
    }
    t.ok("空 token 的招募链接也必须报错（与 tokens/idem 同口径）", threw4)

    /* P1 M-3：限流状态不落盘 —— 保存后 db.json 里不应出现 login_fail */
    let lf = LoginFail()
    lf.count = 3
    lf.first_at = 1789898400
    s.login_fail["13800000000"] = lf
    storeSaveNow(s)
    let after = String.fromUtf8(File.readFrom(s.dbFile()))
    t.ok("login_fail 不落盘（M-3）", !containsAscii(after, "login_fail"))
    /* 但内存里仍然有效（限流照常工作） */
    t.ok("login_fail 仍在内存", s.login_fail.size == 1)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    if (exists(dir + "-m7")) {
        remove(dir + "-m7", recursive: true)
    }
    if (exists(dir + "-n5")) {
        remove(dir + "-n5", recursive: true)
    }
}

/* ===================== 权限 ===================== */

func mkMember(id: Int64, role: String, dept: Int64): Member {
    let m = Member()
    m.id = id
    m.role = role
    m.dept_id = dept
    m.status = "active"
    return m
}

func testPerms(t: TR): Unit {
    println("- perms 权限判定")
    let pres = mkMember(1, "president", 1)
    let vp = mkMember(2, "vice_president", 1)
    let lead = mkMember(7, "lead", 2)
    let vice = mkMember(8, "vice_lead", 2)
    let mem = mkMember(9, "member", 2)
    let pending = mkMember(10, "", 0)
    pending.status = "pending"
    let disabled = mkMember(11, "member", 2)
    disabled.status = "disabled"

    let own = Target()
    own.dept_id = 2
    /* 目标档位：自己的部门里的一个普通成员。
     * 必须显式填 —— H-1 之后「档位」是权限判定的一部分，
     * target_role 留空会按"目标档位未知"一律拒绝。 */
    own.member_id = 9
    own.target_role = "member"
    let other = Target()
    other.dept_id = 3
    other.member_id = 90
    other.target_role = "member"
    let presTarget = Target()
    presTarget.member_id = 1
    presTarget.target_role = "president"
    presTarget.dept_id = 1
    let selfTask = Target()
    selfTask.is_self = true
    selfTask.owner_id = 9
    selfTask.dept_id = 3
    let creatorTask = Target()
    creatorTask.creator_id = 7
    creatorTask.dept_id = 3
    let ownedPlan = Target()
    ownedPlan.owner_id = 7
    ownedPlan.dept_id = 3

    /* 会长 */
    t.ok("会长移交", can(pres, Action.TransferPresidency, other))
    t.ok("会长建部门", can(pres, Action.ManageDept, other))
    t.ok("会长删部门", can(pres, Action.DeleteDept, other))
    t.ok("会长改会长本人", can(pres, Action.SetRole, presTarget))
    t.ok("会长跨部门建任务", can(pres, Action.CreateTask, other))

    /*
     * 运维（ops，2026-09-16）：**除「移交会长」外与会长同权**。
     * 存在的理由：运维不该由会长本人执行（职责分离）—— 运维台用专用账号调 club-server，
     * 审计里 actor 就是运维账号。这里把"同权"和"唯一减法"都钉住：
     * 少一条就会悄悄退化成副会长档（做不了部门增删改、换不了注册口令）。
     */
    let ops = mkMember(3, "ops", 0)   /* 运维不属于任何部门：dept_id = 0 */
    t.ok("运维不能移交会长（唯一减法）", !can(ops, Action.TransferPresidency, other))
    t.eqs("运维移交会长被拒的错误码", checkAccess(ops, Action.TransferPresidency, other) ?? "", "FORBIDDEN_ROLE")
    t.ok("运维可增改部门（会长独占的那几项）", can(ops, Action.ManageDept, other))
    t.ok("运维可删部门", can(ops, Action.DeleteDept, other))
    t.ok("运维可换注册口令", can(ops, Action.ChangeRegisterCode, other))
    t.ok("运维可看注册口令", can(ops, Action.ViewRegisterCode, other))
    t.ok("运维可管招募链接", can(ops, Action.ManageInviteLink, other))
    t.ok("运维可跨部门建任务（全社团范围）", can(ops, Action.CreateTask, other))
    /* 与会长**同档**，但要能处置会长 —— "会长忘口令、运维帮他重置"正是典型运维场景。
     * （权限层放行；handler 另有「最后一个会长」保护，见 h_member.cj 的 FORBIDDEN_LAST_PRESIDENT。） */
    t.ok("运维可重置会长的口令", can(ops, Action.ResetPassword, presTarget))
    t.ok("运维可禁用会长（handler 另有最后一个会长保护）", can(ops, Action.DisableMember, presTarget))
    t.ok("运维可改会长的角色", can(ops, Action.SetRole, presTarget))
    /* 但「重置密码不含本人」这条对它照旧（作废自己全部令牌 = 响应 200 后自己掉线） */
    let opsSelf = Target()
    opsSelf.member_id = 3
    opsSelf.target_role = "ops"
    t.ok("运维不能重置自己的口令（N-7 口径照旧）", !can(ops, Action.ResetPassword, opsSelf))
    /* 这一档**不可由 API 分配**：否则会长能造出权限略高于自己的账号 */
    t.ok("ops 不是可分配角色（只能由 init-ops 创建）", !isKnownRole("ops"))
    t.eqs("ops 的角色中文名", roleLabel("ops"), "运维")
    t.ok("运维权限摘要：manage_depts 为真", reqBoolOr(permissionsOf(ops), "manage_depts", false))
    t.ok("运维权限摘要：change_register_code 为真", reqBoolOr(permissionsOf(ops), "change_register_code", false))
    t.ok("运维权限摘要：transfer_presidency 为假", !reqBoolOr(permissionsOf(ops), "transfer_presidency", true))
    /* 反向闸门：副会长档没有因为新增 ops 被顺手放开 */
    t.ok("副会长仍不能增改部门（未因 ops 放开）", !can(vp, Action.ManageDept, other))
    t.ok("副会长仍不能换注册口令（未因 ops 放开）", !can(vp, Action.ChangeRegisterCode, other))

    /* 副会长：除移交与改动会长本人外同权 */
    t.ok("副会长不能移交", !can(vp, Action.TransferPresidency, other))
    t.ok("副会长不能改会长本人", !can(vp, Action.SetRole, presTarget))
    t.ok("副会长不能禁用会长", !can(vp, Action.DisableMember, presTarget))
    t.ok("副会长可改他人角色", can(vp, Action.SetRole, other))
    t.ok("副会长不能增改部门（会长独占）", !can(vp, Action.ManageDept, other))
    t.ok("副会长不能删部门（会长独占）", !can(vp, Action.DeleteDept, other))
    t.ok("副会长可看口令", can(vp, Action.ViewRegisterCode, other))
    t.ok("副会长不可换口令", !can(vp, Action.ChangeRegisterCode, other))
    t.ok("副会长可管招募链接", can(vp, Action.ManageInviteLink, other))
    t.ok("部长不能增改部门", !can(lead, Action.ManageDept, own))
    t.ok("部长不能删部门", !can(lead, Action.DeleteDept, own))

    /* 部长 / 副部长：同权，限本部门 */
    t.ok("部长本部门建任务", can(lead, Action.CreateTask, own))
    t.ok("部长跨部门建任务 拒", !can(lead, Action.CreateTask, other))
    t.ok("副部长与部长同权", can(vice, Action.CreateTask, own))
    t.ok("部长建部门 拒", !can(lead, Action.ManageDept, own))
    t.ok("部长调部门 拒", !can(lead, Action.SetRole, own))
    t.ok("部长审批 拒", !can(lead, Action.AssignPending, own))
    t.ok("部长改本部门成员姓名", can(lead, Action.EditMemberName, own))
    t.ok("部长改外部门成员姓名 拒", !can(lead, Action.EditMemberName, other))
    t.ok("部长建课题", can(lead, Action.CreatePlan, own))
    t.ok("部长移动课题", can(lead, Action.MovePlan, own))

    /*
     * P0 H-1：档位规则。上面第 372 行只测了「副会长不能改会长本人」，
     * 而漏洞出在**部长**分支——部长拿到同部门的会长目标时畅通无阻。
     * 注意这里的目标刻意取**同部门**（dept 2 = 部长自己那个部门），
     * 否则 403 会是 FORBIDDEN_NOT_IN_DEPT 挡下来的，测了个假绿灯。
     */
    let sameDeptPres = Target()
    sameDeptPres.member_id = 1
    sameDeptPres.target_role = "president"
    sameDeptPres.dept_id = 2
    let sameDeptVp = Target()
    sameDeptVp.member_id = 2
    sameDeptVp.target_role = "vice_president"
    sameDeptVp.dept_id = 2
    let sameDeptLead = Target()
    sameDeptLead.member_id = 5
    sameDeptLead.target_role = "lead"
    sameDeptLead.dept_id = 2
    let sameDeptMember = Target()
    sameDeptMember.member_id = 9
    sameDeptMember.target_role = "member"
    sameDeptMember.dept_id = 2
    /* 「另一位副会长」：member_id 刻意不等于任何操作者本人，用来测**同权之间**的约束。
     * （sameDeptVp 的 member_id=2 恰好就是 vp 自己，拿它测同权会测成"对自己"。） */
    let peerVp = Target()
    peerVp.member_id = 12
    peerVp.target_role = "vice_president"
    peerVp.dept_id = 1

    t.ok("部长改同部门会长姓名 拒（H-1）", !can(lead, Action.EditMemberName, sameDeptPres))
    t.ok("部长重置同部门会长密码 拒（H-1）", !can(lead, Action.ResetPassword, sameDeptPres))
    t.eqs("部长动会长的错误码是角色维度（H-1）",
        checkAccess(lead, Action.ResetPassword, sameDeptPres) ?? "", "FORBIDDEN_ROLE")
    t.ok("副部长同样改不了会长本人（H-1）", !can(vice, Action.EditMemberName, sameDeptPres))
    t.ok("部长改同部门副会长姓名 拒（H-1）", !can(lead, Action.EditMemberName, sameDeptVp))
    t.ok("部长重置同部门副会长密码 拒（H-1）", !can(lead, Action.ResetPassword, sameDeptVp))
    t.ok("部长改同部门另一位部长姓名 拒（同档）", !can(lead, Action.EditMemberName, sameDeptLead))
    t.ok("部长改同部门普通成员姓名 允许", can(lead, Action.EditMemberName, sameDeptMember))
    t.ok("部长重置同部门普通成员密码 允许", can(lead, Action.ResetPassword, sameDeptMember))
    t.ok("副会长改会长本人仍拒", !can(vp, Action.EditMemberName, sameDeptPres))
    /* 同权约束推广（2026-09-14）：改名 / 改角色 / 禁用也一律不可作用于同权或更高权的人。
     * 注意 sameDeptVp.member_id == vp.id == 2，对 vp 而言那是**自己**——原断言写作
     * "副会长可改另一位副会长"其实名不副实。现在拆成两条：改自己（自己例外，仍允许）
     * 与改另一位副会长（同权，拒）。 */
    t.ok("副会长改自己的角色（自己例外）", can(vp, Action.SetRole, sameDeptVp))
    t.ok("副会长改另一位副会长的角色 拒（同权）", !can(vp, Action.SetRole, peerVp))
    t.ok("副会长禁用另一位副会长 拒（同权）", !can(vp, Action.DisableMember, peerVp))
    t.ok("副会长改另一位副会长的姓名 拒（同权）", !can(vp, Action.EditMemberName, peerVp))
    t.ok("会长仍可改副会长的角色（未过度收紧）", can(pres, Action.SetRole, peerVp))
    t.ok("会长仍可禁用副会长（未过度收紧）", can(pres, Action.DisableMember, peerVp))
    /* N-7：「重置密码**不含本人**」这条约束只能由 checkAccess 的动作语义层拦住——
     * 会长与副会长的角色分支都是"直接放行"（roleAllows 里 president 一档 return true、
     * 副会长档只排除 president）。
     *
     * 注意 sameDeptPres.member_id == pres.id == 1，对 pres 而言它字面上就是"自己"：
     * 原先这里写的是 `can(pres, ResetPassword, sameDeptPres)` 且断言为 true，
     * 也就是"会长可以重置自己"——那正是 N-7 要修掉的行为（会把自己的令牌全部作废，
     * 表现为"响应 200、自己当场掉线"）。现在改用 sameDeptVp（member_id=2，是别人）
     * 来测"不受档位限制"。
     *
     * 同一对 Target 正好也覆盖副会长：sameDeptVp.member_id == vp.id == 2。 */
    t.ok("会长重置他人不受档位限制", can(pres, Action.ResetPassword, sameDeptVp))
    /* 通用规则：不可作用于与自己**同权或更高权**的人 —— N-7 只是它的特例
     * （对自己而言就是同权）。副会长之间互为同权，原先没有这条约束，
     * 副会长可以把另一位副会长重置下线 / 降级 / 禁用。 */
    t.ok("副会长重置另一位副会长（同权）拒", !can(vp, Action.ResetPassword, peerVp))
    t.eqs("同权被拒的错误码（动作语义层）",
        checkAccess(vp, Action.ResetPassword, peerVp) ?? "", "FORBIDDEN_ROLE")
    t.ok("会长重置副会长（更低档）允许", can(pres, Action.ResetPassword, peerVp))
    t.ok("副会长重置部长（更低档）允许", can(vp, Action.ResetPassword, sameDeptLead))
    t.ok("会长重置普通成员（更低档）允许", can(pres, Action.ResetPassword, sameDeptMember))
    /* N-10：assign / assign-batch 同样写 role 与 status，属成员处置类动作，
     * 必须受同一条同权约束（第一次推广时漏了它们，副会长据此仍可降级同权者，
     * 甚至把会长刚移出的同权副会长"复活"）。 */
    t.ok("副会长用 assign 降级另一位副会长 拒（N-10）", !can(vp, Action.AssignPending, peerVp))
    t.ok("会长用 assign 调整副会长 允许（未过度收紧）", can(pres, Action.AssignPending, peerVp))
    let pendingTgt = Target()
    pendingTgt.member_id = 20
    pendingTgt.target_role = ""        /* 待分配成员还没有角色（档位 0） */
    pendingTgt.dept_id = 0
    t.ok("副会长审批待分配成员 允许（N-10 未误拦 pending）", can(vp, Action.AssignPending, pendingTgt))
    t.ok("会长对自己重置 拒（N-7）", !can(pres, Action.ResetPassword, sameDeptPres))
    t.eqs("会长对自己重置的错误码（N-7）",
        checkAccess(pres, Action.ResetPassword, sameDeptPres) ?? "", "FORBIDDEN_ROLE")
    t.ok("副会长对自己重置 拒（N-7）", !can(vp, Action.ResetPassword, sameDeptVp))
    /* 目标档位未知时宁拒不放过 */
    let unknownRole = Target()
    unknownRole.dept_id = 2
    t.ok("目标档位未知 拒（防漏填 target_role）", !can(lead, Action.ResetPassword, unknownRole))
    /*
     * 2026-09-17（P1 加固）：空串 target_role 的**两种含义必须分清**。
     * 上面那条之所以"拒"，靠的其实是角色维度（lead 档对空档位不放行）；
     * 副会长 / 会长档在 roleAllows 里是直接放行，只有 perms 的同权闸拦得住 ——
     * 而那里原来是 fail open（roleRank("") == 0，比谁都低），于是"漏填 target_role"
     * 会让同权保护静默失效。现在：漏填（未声明 role_absent）一律拒。
     */
    let forgotFill = Target()
    forgotFill.member_id = 30
    forgotFill.dept_id = 2
    t.ok("漏填 target_role：副会长改名 拒（P1 加固，原 fail open）",
        !can(vp, Action.EditMemberName, forgotFill))
    t.ok("漏填 target_role：副会长改角色 拒（P1 加固）", !can(vp, Action.SetRole, forgotFill))
    t.ok("漏填 target_role：副会长禁用 拒（P1 加固）", !can(vp, Action.DisableMember, forgotFill))
    t.eqs("漏填 target_role 的错误码", checkAccess(vp, Action.SetRole, forgotFill) ?? "", "FORBIDDEN_ROLE")
    /* 反向闸门：**待分配目标（显式声明没有角色）不能被误拦** ——
     * 会长把刚注册的申请人改名是正常流程（冒烟 §22.5 的 N-15 段就走这条）。 */
    let pendingDeclared = Target()
    pendingDeclared.member_id = 31
    pendingDeclared.dept_id = 2
    pendingDeclared.role_absent = true
    t.ok("声明 role_absent（待分配）不被误拦：会长改名 允许", can(pres, Action.EditMemberName, pendingDeclared))

    /* 成员 */
    t.ok("成员看名录（全社团）", can(mem, Action.ViewMembers, other))
    t.ok("成员看本部门任务", can(mem, Action.ViewTasks, own))
    /*
     * D-3（2026-09-16）：读范围按设计规格放开到全社团。
     * 原先这里断言"成员看外部门任务 拒"——那是 v1-scope §3.4.3 的旧口径；
     * 设计规格 P02「共 38 项 · 全社团范围可见」、P04 用「全部」筛选、P03「部长在首页即可看到这条」
     * 三处都是全社团可读。这条断言会随回退变红，是本次改动的回归闸门。
     */
    t.ok("成员看外部门任务（D-3 全社团可读）", can(mem, Action.ViewTasks, other))
    t.ok("成员改自己任务状态（跨部门也行）", can(mem, Action.UpdateTaskStatus, selfTask))
    t.ok("成员改本部门他人任务状态 拒（写范围未放开）", !can(mem, Action.UpdateTaskStatus, own))
    t.ok("成员改外部门他人任务状态 拒（D-3 只放开读）", !can(mem, Action.UpdateTaskStatus, other))
    t.ok("成员建任务 拒", !can(mem, Action.CreateTask, own))
    t.ok("成员换口令 拒", !can(mem, Action.ChangeRegisterCode, own))
    t.ok("成员移交 拒", !can(mem, Action.TransferPresidency, other))

    /* 创建人 / 负责人条款 */
    t.ok("创建人可编辑任务（跨部门）", can(lead, Action.EditTask, creatorTask))
    t.ok("创建人可删除任务（跨部门）", can(lead, Action.DeleteTask, creatorTask))
    /*
     * 2026-09-17（P1）：课题负责人条款**必须同部门**。
     *
     * 这里原先断言的是「负责人可编辑课题（**跨部门**）」—— 而那正是漏洞本身：
     * A 部门的课题只要把负责人写成 B 部门的人，B 部门那个人就拿到了这个课题的写权限
     * （创建路径与 PATCH 换负责人都能造出这种状态，任务侧 N-18 早已堵住、课题侧没有）。
     * 现在：同部门负责人照旧放行，跨部门负责人落到部门兜底判定上（拒）。
     * 原断言已按新口径改写 —— 它固化的是一条跨部门写权限，不是期望行为。
     */
    let ownedPlanSameDept = Target()
    ownedPlanSameDept.owner_id = 7
    ownedPlanSameDept.dept_id = lead.dept_id
    t.ok("负责人可编辑课题（同部门）", can(lead, Action.EditPlan, ownedPlanSameDept))
    t.ok("跨部门负责人编辑课题 拒（P1 修复）", !can(lead, Action.EditPlan, ownedPlan))
    t.eqs("跨部门负责人编辑课题的错误码",
        checkAccess(lead, Action.EditPlan, ownedPlan) ?? "", "FORBIDDEN_NOT_IN_DEPT")

    /* 状态维度 */
    t.ok("pending 一律拒绝", !can(pending, Action.ViewMembers, own))
    t.ok("disabled 一律拒绝", !can(disabled, Action.ViewMembers, own))
    t.eqs("pending 错误码", checkAccess(pending, Action.ViewMembers, own) ?? "", "MEMBER_PENDING")
    t.eqs("disabled 错误码", checkAccess(disabled, Action.ViewMembers, own) ?? "", "MEMBER_DISABLED")
    t.eqs("跨部门错误码", checkAccess(lead, Action.CreateTask, other) ?? "", "FORBIDDEN_NOT_IN_DEPT")
    t.eqs("角色错误码", checkAccess(mem, Action.CreateTask, own) ?? "", "FORBIDDEN_ROLE")

    /* 会长人数（规则 10） */
    let s = Store("build/test-data-perm")
    let m1 = mkMember(1, "president", 1)
    let m2 = mkMember(2, "lead", 2)
    s.members[1] = m1
    s.members[2] = m2
    t.eqi("会长人数=1", presidentCount(s), 1)
    let m3 = mkMember(3, "president", 1)
    s.members[3] = m3
    t.eqi("会长人数=2", presidentCount(s), 2)
    let m4 = mkMember(4, "president", 1)
    m4.status = "disabled"
    s.members[4] = m4
    t.eqi("禁用的会长不计入", presidentCount(s), 2)

    /*
     * 2026-10-06（用户报的 bug）：**AI 的权限清单必须与 can() 一致**。
     *
     * aiPermFacts 原先用一个 target_role 留空的**合成目标**去问 can()，
     * 而 perms.cj 的 outranks() 对空档位是**故意 fail-closed** 的
     * （注释原文："目标档位未知（空串）：宁拒不放过"）—— 于是
     *     部长 + Action.ResetPassword -> outranks("lead", "") -> false
     * **部长的权限清单里少了「重置成员口令」**，而服务端实际上允许他重置本部门普通成员
     * 的口令（上面那条断言就是），界面上真做也会成功 200。
     * 这份清单被当作"系统判定的权威结论"喂给模型、也直接回给用户，
     * 所以这不是"AI 说错权限"，而是**我们喂给它的事实错了**。
     *
     * 回退即变红：把 aiPermFacts 里 target_role 那行删掉，本断言立刻失败。
     */
    let aiLead = Member()
    aiLead.role = "lead"
    aiLead.dept_id = 2
    /* ⚠ Member() 的 status 默认是 "pending"，而 checkAccess 一进门就
       `if (m.status == "pending") return Some("MEMBER_PENDING")` ——
       不填 active 会让 21 项**全被判否**，测试就成了空转（第一版就踩了这个）。 */
    aiLead.status = "active"
    let aiFacts = aiPermFacts(aiLead)
    t.ok("AI 权限清单：部长含「重置成员口令」（回退即变红）",
         containsAscii(aiFacts, "重置成员口令"))
    t.ok("AI 权限清单：部长非空（不能把 21 项全判否）", aiFacts.size > 20)
}

/* ===================== 视图 ===================== */

func testViews(t: TR): Unit {
    println("- views 对外视图")
    let s = Store("build/test-data-views")
    let d = Department()
    d.id = 1
    d.name = "运营部"
    s.departments[1] = d

    let m = Member()
    m.id = 5
    m.name = "LiSi"
    m.phone = "13900000000"
    m.role = "lead"
    m.dept_id = 1
    m.status = "active"
    m.joined_at = 1767196800
    s.members[5] = m

    let brief = memberBrief(s, m).toString()
    t.ok("MemberBrief 不含手机号", !containsAscii(brief, "13900000000"))
    t.ok("MemberBrief 含姓名", containsAscii(brief, "LiSi"))
    t.ok("MemberBrief 含部门名", containsAscii(brief, "运营部"))

    let self = memberSelf(s, m).toString()
    t.ok("本人视图含手机号", containsAscii(self, "13900000000"))

    /* D-3：读范围全社团 → active 的 view_scope 一律 all（除 pending 为 none） */
    t.eqs("lead view_scope（D-3 全社团可读）", jsonGetStr(permissionsOf(m), "view_scope") ?? "", "all")
    t.ok("lead 不能设角色", (jsonGetBool(permissionsOf(m), "set_role") ?? true) == false)
    t.ok("lead 能建任务", (jsonGetBool(permissionsOf(m), "create_task") ?? false))
    /* D-1：管理页四张分区卡的驱动布尔 —— 部长一个都不该有 */
    t.ok("lead 不能管部门（D-1）", (jsonGetBool(permissionsOf(m), "manage_depts") ?? true) == false)
    t.ok("lead 不能读口令（D-1）", (jsonGetBool(permissionsOf(m), "view_register_code") ?? true) == false)
    t.ok("lead 不能换口令（D-1）", (jsonGetBool(permissionsOf(m), "change_register_code") ?? true) == false)
    t.ok("lead 不能管链接（D-1）", (jsonGetBool(permissionsOf(m), "manage_invite_links") ?? true) == false)
    t.ok("lead 不能移交（D-1）", (jsonGetBool(permissionsOf(m), "transfer_presidency") ?? true) == false)

    let pres = mkMember(1, "president", 1)
    t.eqs("president view_scope", jsonGetStr(permissionsOf(pres), "view_scope") ?? "", "all")
    t.ok("president 能设角色", (jsonGetBool(permissionsOf(pres), "set_role") ?? false))
    /* D-1：会长独占项 */
    t.ok("president 能管部门（D-1）", (jsonGetBool(permissionsOf(pres), "manage_depts") ?? false))
    t.ok("president 能换口令（D-1）", (jsonGetBool(permissionsOf(pres), "change_register_code") ?? false))
    t.ok("president 能移交（D-1）", (jsonGetBool(permissionsOf(pres), "transfer_presidency") ?? false))

    /*
     * L-1：set_role 必须与真实权限一致。副会长**能**改他人角色（只有会长本人动不了），
     * 原先 permissionsOf 写死 role == "president"，客户端据此把副会长的角色入口藏了。
     */
    let vpView = mkMember(2, "vice_president", 1)
    t.ok("vice_president 能设角色（L-1）", (jsonGetBool(permissionsOf(vpView), "set_role") ?? false))
    t.ok("vice_president manage_members", (jsonGetBool(permissionsOf(vpView), "manage_members") ?? false))
    /*
     * D-1 的关键反例：副会长能管人，但**不能管组织、不能换口令、不能移交**。
     * 只下发 manage_members 时，客户端会让副会长看到「部门与组织」入口然后被 403
     * ——正是设计规格 P10「按权限显示的管理入口」要避免的场景。
     */
    t.ok("vice_president 能读口令（D-1）", (jsonGetBool(permissionsOf(vpView), "view_register_code") ?? false))
    t.ok("vice_president 能管链接（D-1）", (jsonGetBool(permissionsOf(vpView), "manage_invite_links") ?? false))
    t.ok("vice_president 不能管部门（D-1）", (jsonGetBool(permissionsOf(vpView), "manage_depts") ?? true) == false)
    t.ok("vice_president 不能换口令（D-1）", (jsonGetBool(permissionsOf(vpView), "change_register_code") ?? true) == false)
    t.ok("vice_president 不能移交（D-1）", (jsonGetBool(permissionsOf(vpView), "transfer_presidency") ?? true) == false)
    let viceView = mkMember(8, "vice_lead", 2)
    t.ok("vice_lead 不能设角色", (jsonGetBool(permissionsOf(viceView), "set_role") ?? true) == false)

    let mem = mkMember(9, "member", 2)
    t.eqs("member view_scope（D-3 全社团可读）", jsonGetStr(permissionsOf(mem), "view_scope") ?? "", "all")
    t.ok("member 不能改他人任务", (jsonGetBool(permissionsOf(mem), "update_any_task") ?? true) == false)

    let pend = mkMember(10, "", 0)
    pend.status = "pending"
    t.eqs("pending view_scope", jsonGetStr(permissionsOf(pend), "view_scope") ?? "", "none")
    t.ok("pending 无任何权限", (jsonGetBool(permissionsOf(pend), "create_task") ?? true) == false)

    t.ok("角色名合法", isKnownRole("vice_lead"))
    t.ok("角色名非法", !isKnownRole("admin"))
    t.eqs("角色中文名", roleLabel("vice_president"), "副会长")
}

/* ===================== Part 3 的视图与查询 ===================== */

func testPart3Views(t: TR): Unit {
    println("- views(Part3) 部门/成员/待分配/链接")
    let s = Store("build/test-data-p3")
    let d1 = Department()
    d1.id = 1
    d1.name = "主席团"
    d1.sort = 0
    let d2 = Department()
    d2.id = 2
    d2.name = "运营部"
    d2.sort = 2
    s.departments[1] = d1
    s.departments[2] = d2

    let pres = Member()
    pres.id = 1
    pres.name = "会长"
    pres.phone = "13800000000"
    pres.role = "president"
    pres.dept_id = 1
    pres.status = "active"
    pres.joined_at = 1767196800
    s.members[1] = pres

    let lead = Member()
    lead.id = 2
    lead.name = "部长"
    lead.phone = "13800000002"
    lead.role = "lead"
    lead.dept_id = 2
    lead.status = "active"
    lead.joined_at = 1767196800
    s.members[2] = lead

    let member = Member()
    member.id = 3
    member.name = "成员"
    member.phone = "13800000003"
    member.role = "member"
    member.dept_id = 2
    member.status = "active"
    member.joined_at = 1767196800
    s.members[3] = member

    let gone = Member()
    gone.id = 4
    gone.name = "已退出"
    gone.phone = "13800000004"
    gone.role = "member"
    gone.dept_id = 2
    gone.status = "disabled"
    gone.joined_at = 1767196800
    s.members[4] = gone

    let pend = Member()
    pend.id = 5
    pend.name = "新人"
    pend.phone = "13800000005"
    pend.status = "pending"
    pend.dept_hint = 2
    pend.joined_at = 1789898400
    s.members[5] = pend

    /* 部门视图：部长现查现算（没有 lead_id 字段） */
    let dv = deptView(s, d2).toString()
    t.ok("部门含部长姓名", containsAscii(dv, "部长"))
    t.ok("部门人数=2（active，不含已退出）", containsAscii(dv, "\"member_count\":2"))
    t.ok("部门不含手机号", !containsAscii(dv, "13800000002"))

    let dv1 = deptView(s, d1).toString()
    t.ok("主席团无部长时 lead 为 null", containsAscii(dv1, "\"lead\":null"))

    /* 部门顺序：sort 0 在 2 前面 */
    let ds = sortedDepartments(s)
    t.eqi("部门数", ds.size, 2)
    t.eqs("按 sort 排序", ds[0].name, "主席团")

    /*
     * P1 M-8：排序键必须对越界 sort 免疫。
     * 磁盘上可能已经有旧版本写下的超大 sort（那时接口不校验），
     * `sort * 1000000 + id` 会溢出成一个大负数，让排序结果颠倒甚至继续破坏后续逻辑。
     * 这里直接塞一个 Int64 最大值，要求函数不抛异常、结果仍确定。
     */
    let huge = Department()
    huge.id = 3
    huge.name = "越界部门"
    huge.sort = 9223372036854775807
    s.departments[3] = huge
    let ds2 = sortedDepartments(s)
    t.eqi("越界 sort 不丢部门", ds2.size, 3)
    t.ok("越界 sort 仍能排序（不抛异常）", ds2[0].name == "主席团")
    s.departments.remove(3)

    /* 成员排序：部门 sort → id（未分配部门排最后） */
    let picked = ArrayList<Member>()
    picked.add(s.members[3])
    picked.add(s.members[5])
    picked.add(s.members[1])
    let sorted = sortedMembers(s, picked)
    t.eqs("成员排序：主席团(sort0) 最前", sorted[0].name, "会长")
    t.eqs("成员排序：未分配部门最后", sorted[sorted.size - 1].name, "新人")

    /*
     * 2026-09-16（读码发现的口径裂缝）：**未分配部门的哨兵必须大于 SORT_MAX**。
     *
     * 原先 `sortedMembers` 把哨兵写死成 999，而 sort 的合法上界是 10000（SORT_MAX）——
     * 于是只要有一个部门的 sort ≥ 999，未分配成员就会排到它**前面**，
     * 与上面那条"未分配部门最后"的断言在小数据量下看不出、一到真实数据就相反。
     * 这里造一个 sort=1000 的部门（客户端可以显式传，合法），再加一个该部门的成员：
     * 旧写法下 `新人`（哨兵 999）会排在他前面 → 这条断言变红。
     */
    let dHigh = Department()
    dHigh.id = 9
    dHigh.name = "排序靠后的部门"
    dHigh.sort = 1000
    s.departments[9] = dHigh
    let inHigh = Member()
    inHigh.id = 9
    inHigh.name = "靠后部门成员"
    inHigh.role = "member"
    inHigh.dept_id = 9
    inHigh.status = "active"
    s.members[9] = inHigh
    let picked2 = ArrayList<Member>()
    picked2.add(s.members[5])   /* 未分配（dept 0）*/
    picked2.add(s.members[9])   /* sort=1000 的部门 */
    let sorted2 = sortedMembers(s, picked2)
    t.eqs("成员排序：sort=1000 的部门排在未分配之前", sorted2[0].name, "靠后部门成员")
    t.eqs("成员排序：未分配仍然最后（哨兵 > SORT_MAX）", sorted2[1].name, "新人")
    s.departments.remove(9)
    s.members.remove(9)

    /* 成员详情：计数摘要 */
    let task = Task()
    task.id = 1
    task.title = "T1"
    task.owner_id = 2
    task.status = "doing"
    task.dept_id = 2
    /* D-7：身份卡的「逾期 1」要有来源 —— 给这条挂一个已过的截止时间 */
    task.due_at = 1789898400 - 7200
    s.tasks[1] = task
    let task2 = Task()
    task2.id = 2
    task2.title = "T2"
    task2.owner_id = 2
    task2.status = "done"
    task2.dept_id = 2
    s.tasks[2] = task2
    let task3 = Task()
    task3.id = 3
    task3.title = "T3(已删)"
    task3.owner_id = 2
    task3.status = "doing"
    task3.deleted_at = 1789898400
    s.tasks[3] = task3
    let plan = Plan()
    plan.id = 1
    plan.title = "P1"
    plan.owner_id = 2
    plan.dept_id = 2
    s.plans[1] = plan

    let detail = memberDetailView(s, s.members[2], 1789898400).toString()
    t.ok("owned_tasks=2（软删除不计）", containsAscii(detail, "\"owned_tasks\":2"))
    t.ok("open_tasks=1", containsAscii(detail, "\"open_tasks\":1"))
    t.ok("owned_plans=1", containsAscii(detail, "\"owned_plans\":1"))
    /*
     * D-7（2026-09-16）：设计规格 P07 的身份卡是「未完成 5 · 逾期 1 · 已完成 12」——
     * 三个计数都得服务端给。「已完成」原先要靠 owned-open 自己减，
     * 「逾期」则根本推不出来（只能再打一次任务列表）。这两条断言是回归闸门。
     */
    t.ok("done_tasks=1（D-7）", containsAscii(detail, "\"done_tasks\":1"))
    t.ok("overdue_tasks=1（D-7）", containsAscii(detail, "\"overdue_tasks\":1"))
    t.ok("详情不含手机号", !containsAscii(detail, "13800000002"))

    /*
     * D-2（2026-09-16）：名录搜索 —— 匹配**姓名 OR 部门名**
     * （设计规格 P06 搜索框占位符「搜索姓名或部门」）。
     * 纯函数覆盖，不依赖 HTTP；手机号**不参与匹配**（P06「名录不含手机号」）。
     */
    t.ok("搜索：姓名命中（D-2）", memberMatchesQuery(s, s.members[3], "成员"))
    t.ok("搜索：部门名命中（D-2）", memberMatchesQuery(s, s.members[3], "运营"))
    t.ok("搜索：姓名与部门都不匹配 → 不命中（D-2）", !memberMatchesQuery(s, s.members[3], "宣传部"))
    t.ok("搜索：主席团的人不被「运营」命中（D-2）", !memberMatchesQuery(s, s.members[1], "运营"))
    t.ok("搜索：待分配按 dept_hint 命中（D-2）", memberMatchesQuery(s, s.members[5], "运营"))
    t.ok("搜索：手机号不参与匹配（隐私，D-2）", !memberMatchesQuery(s, s.members[3], "13800000003"))

    /*
     * D-16（2026-09-16）：招募链接 → 部门预填，由**服务端**从 token 推导。
     * 三条反例（停用 / 不存在 / 畸形）都必须给 0，否则"停用的链接还能预填部门"
     * 会让招募链接的启停形同虚设。
     */
    let liveLink = DeptInviteLink()
    liveLink.token = "live-token-32"
    liveLink.dept_id = 2
    liveLink.enabled = true
    s.invite_links["live-token-32"] = liveLink
    let deadLink = DeptInviteLink()
    deadLink.token = "dead-token-32"
    deadLink.dept_id = 2
    deadLink.enabled = false
    s.invite_links["dead-token-32"] = deadLink
    t.eqi("D16 启用中的链接 → 解析出部门", resolveInviteDept(s, "live-token-32"), 2)
    t.eqi("D16 已停用的链接 → 0（启停必须真的生效）", resolveInviteDept(s, "dead-token-32"), 0)
    t.eqi("D16 不存在的 token → 0", resolveInviteDept(s, "no-such-token"), 0)
    t.eqi("D16 空 token → 0", resolveInviteDept(s, ""), 0)
    /* 65 字节：32 字节十六进制是 64 个字符，再补一个（String 没有 repeat，别踩） */
    t.eqi("D16 超长 token → 0（不做无谓查表）", resolveInviteDept(s, randHex(32) + "x"), 0)

    /* 未完成任务：只算 owner 匹配且未完成且未删除 */
    let open = openTasksOf(s, 2)
    t.eqi("未完成任务数", open.size, 1)
    t.eqs("未完成任务标题", open[0].title, "T1")

    /* 待分配视图 */
    let pv = pendingView(s, s.members[5]).toString()
    t.ok("待分配含 dept_hint 部门名", containsAscii(pv, "运营部"))
    t.ok("待分配含 registered_at", containsAscii(pv, "registered_at"))
    t.ok("待分配 role 为 null", containsAscii(pv, "\"role\":null"))

    /* 待分配列表顺序 = 注册顺序（id 升序） */
    let pending = pendingMembers(s)
    t.eqi("待分配人数", pending.size, 1)

    /* 部门前置检查 */
    t.eqi("运营部未退出成员数（部长+成员，不含已退出）", activeMemberCountOfDept(s, 2), 2)
    t.ok("部门重名检测", deptNameTaken(s, "运营部", 0))
    t.ok("改名时排除自身", !deptNameTaken(s, "运营部", 2))

    /* 招募链接视图 */
    let l = DeptInviteLink()
    l.token = "a1b2c3d4"
    l.dept_id = 2
    l.enabled = true
    l.created_by = 1
    l.created_at = 1789898400
    let lv = inviteLinkView(s, l, "https://example.com/join/a1b2c3d4").toString()
    t.ok("链接含 token", containsAscii(lv, "a1b2c3d4"))
    t.ok("链接含部门名", containsAscii(lv, "运营部"))
    t.ok("链接含 url", containsAscii(lv, "https://example.com/join/a1b2c3d4"))

    /* 注册配置视图 */
    s.register_code = "K3M9P2"
    s.register_code_by = 1
    s.register_code_at = 1789898400
    let rv = registerConfigView(s).toString()
    t.ok("注册配置含口令", containsAscii(rv, "K3M9P2"))
    t.ok("注册配置含操作人", containsAscii(rv, "会长"))
}

func testPaging(t: TR): Unit {
    println("- paging 分页")
    let all = ArrayList<JsonObject>()
    var i: Int64 = 1
    while (i <= 120) {
        let o = JsonObject()
        jPutInt(o, "id", i)
        all.add(o)
        i += 1
    }
    let p1 = pagedSlice(all, 1, 50).toString()
    t.ok("第 1 页 total=120", containsAscii(p1, "\"total\":120"))
    t.ok("第 1 页 page=1", containsAscii(p1, "\"page\":1"))
    t.ok("第 1 页 size=50", containsAscii(p1, "\"size\":50"))

    let p3 = pagedSlice(all, 3, 50)
    t.eqi("第 3 页条目数=20", (jsonGetArray(p3, "items") ?? JsonArray()).size(), 20)

    let pOver = pagedSlice(all, 99, 50)
    t.eqi("越界页返回空", (jsonGetArray(pOver, "items") ?? JsonArray()).size(), 0)

    let pMax = pagedSlice(all, 1, 5000)
    t.ok("size 上限 200", containsAscii(pMax.toString(), "\"size\":200"))

    let pZero = pagedSlice(all, 0, 0)
    t.ok("page<1 归 1", containsAscii(pZero.toString(), "\"page\":1"))
    t.ok("size<1 归 50", containsAscii(pZero.toString(), "\"size\":50"))
}

/* ===================== Part 4 的任务 ===================== */

func testTasks(t: TR): Unit {
    println("- tasks 分组/逾期/派生量")
    let s = Store("build/test-data-tasks")
    /* now = 2026-09-20T18:00:00+08:00；本地日界 todayStart = 1789833600 */
    let now: Int64 = 1789898400
    let todayStart = startOfLocalDay(now)
    let tomorrow = todayStart + 86400
    let weekEnd = todayStart + 7 * 86400

    let owner: Int64 = 7
    let other: Int64 = 8

    func mkTask(id: Int64, ownerId: Int64, due: Int64, status: String): Task {
        let x = Task()
        x.id = id
        x.title = "T${id}"
        x.owner_id = ownerId
        x.dept_id = 2
        x.status = status
        x.due_at = due
        x.created_by = 1
        x.created_at = now
        x.updated_at = now
        return x
    }

    let t1 = mkTask(1, owner, now - 3600, "doing")
    let t2 = mkTask(2, owner, now + 3600, "todo")
    let t3 = mkTask(3, owner, tomorrow + 3600, "todo")
    let t4 = mkTask(4, owner, weekEnd + 3600, "todo")
    let t5 = mkTask(5, owner, 0, "todo")
    let t6 = mkTask(6, owner, now + 7200, "blocked")
    let t7 = mkTask(7, owner, now - 7200, "done")
    let t8 = mkTask(8, other, now + 3600, "todo")
    let t9 = mkTask(9, owner, now + 3600, "todo")
    t9.deleted_at = now
    s.tasks[1] = t1
    s.tasks[2] = t2
    s.tasks[3] = t3
    s.tasks[4] = t4
    s.tasks[5] = t5
    s.tasks[6] = t6
    s.tasks[7] = t7
    s.tasks[8] = t8
    s.tasks[9] = t9

    /* deptScopeId = 0：只看自己的（会长 / 副会长 / 普通成员走这条） */
    let g = groupMine(s, owner, now, 0)
    t.eqi("逾期组", g.overdue.size, 1)
    t.eqs("逾期组内容", g.overdue[0].title, "T1")
    t.eqi("今天组 = T2 + T6", g.due_today.size, 2)
    t.eqs("今天组按截止升序", g.due_today[0].title, "T2")
    t.eqi("本周组", g.due_week.size, 1)
    t.eqi("以后组", g.later.size, 1)
    t.eqi("无截止组", g.no_due.size, 1)
    t.eqi("阻塞组（与今天组并存，不互斥）", g.blocked.size, 1)
    t.eqs("阻塞组内容", g.blocked[0].title, "T6")
    t.eqi("未完成总数（不含 done/deleted/他人）", g.open_total, 6)
    t.eqi("scope=0 时没有 borrowed", g.borrowed, 0)

    /*
     * D-4（2026-09-16）：部长 / 副部长的首页额外带「本部门成员的阻塞项」
     * （设计规格 P03「部长在首页即可看到这条」）。t10 是**别人负责**、
     * 本部门（dept 2）、blocked 的任务 —— 只有传了部门范围才会出现。
     */
    let t10 = mkTask(10, other, now + 3600, "blocked")
    s.tasks[10] = t10
    let gLead = groupMine(s, owner, now, 2)
    t.eqi("部长首页：阻塞组 = 自己的 T6 + 本部门别人的 T10（D-4）", gLead.blocked.size, 2)
    /* 按截止升序：T10 的截止（now+3600）早于 T6（now+7200），所以 T10 在前 */
    t.eqs("部长首页：阻塞组仍按截止升序（D-4）", gLead.blocked[0].title, "T10")
    t.eqs("部长首页：本部门别人的阻塞项也在里面（D-4）", gLead.blocked[1].title, "T6")
    t.eqi("部长首页：borrowed 计数 = 1", gLead.borrowed, 1)
    t.eqi("部长首页：未完成总数含 borrowed", gLead.open_total, 7)
    t.eqi("部长首页：阻塞项同时进时间分组（T10 在今天组）", gLead.due_today.size, 3)
    /* 反例：部门范围不匹配时，别人的阻塞项**不该**出现 */
    let gOtherDept = groupMine(s, owner, now, 99)
    t.eqi("部门范围不匹配 → 不含别人的阻塞项", gOtherDept.blocked.size, 1)
    t.eqi("部门范围不匹配 → borrowed=0", gOtherDept.borrowed, 0)
    /* 非阻塞的别人的任务无论怎样都不进首页 */
    let t11 = mkTask(11, other, now + 3600, "doing")
    s.tasks[11] = t11
    let gLead2 = groupMine(s, owner, now, 2)
    t.eqi("本部门别人的 doing 不进部长首页", gLead2.blocked.size, 2)
    t.eqi("本部门别人的 doing 不计入 borrowed", gLead2.borrowed, 1)

    /* 逾期是派生量 */
    t.ok("未完成且过期 = 逾期", isTaskOverdue(t1, now))
    t.ok("已完成不算逾期", !isTaskOverdue(t7, now))
    t.ok("无截止不算逾期", !isTaskOverdue(t5, now))

    /*
     * D-5（2026-09-16）：逾期**天数**也由服务端下发
     * （设计规格 P03「已逾期 2 天 · 该判断由服务端算出，客户端不重算」）。
     * now = 2026-09-20 18:00，t1 的截止 = now - 3600 = 09-20 17:00 → 同日，0 天；
     * 再压一条两天前的，验证日界差。
     */
    t.eqi("当天逾期 → overdue_days=0", overdueDaysOf(t1, now), 0)
    let t12 = mkTask(12, owner, todayStart - 2 * 86400 + 3600, "doing")
    t.eqi("两天前截止 → overdue_days=2", overdueDaysOf(t12, now), 2)
    t.eqi("未逾期 → overdue_days=0", overdueDaysOf(t2, now), 0)
    t.eqi("已完成 → overdue_days=0", overdueDaysOf(t7, now), 0)
    /* 跨日但不足 24 小时的，按**日界**算 1 天（不是四舍五入成 0） */
    let t13 = mkTask(13, owner, todayStart - 3600, "doing")
    t.eqi("昨天 23:00 截止 → overdue_days=1", overdueDaysOf(t13, now), 1)

    t.ok("状态枚举合法", isTaskStatus("blocked"))
    t.ok("状态枚举非法", !isTaskStatus("doing50"))

    /* 排序：无截止排最后 */
    let mixed = ArrayList<Task>()
    mixed.add(t5)
    mixed.add(t1)
    mixed.add(t4)
    let sorted = sortedTasksByDue(mixed)
    t.eqs("有截止的在前", sorted[0].title, "T1")
    t.eqs("无截止排最后", sorted[2].title, "T5")

    /* 课题子树（M4 的多级课题要靠它） */
    let p1 = Plan()
    p1.id = 1
    p1.title = "根"
    p1.owner_id = 1
    p1.dept_id = 2
    let p2 = Plan()
    p2.id = 2
    p2.title = "子"
    p2.parent_id = 1
    p2.owner_id = 1
    let p3 = Plan()
    p3.id = 3
    p3.title = "孙"
    p3.parent_id = 2
    p3.owner_id = 1
    let p4 = Plan()
    p4.id = 4
    p4.title = "另一棵树"
    p4.owner_id = 1
    p4.dept_id = 2
    s.plans[1] = p1
    s.plans[2] = p2
    s.plans[3] = p3
    s.plans[4] = p4
    let sub = planSubtreeIds(s, 1)
    t.eqi("子树含自身 + 2 个后代", sub.size, 3)
    t.ok("子树含孙节点", sub.contains(3))
    t.ok("子树不含另一棵树", !sub.contains(4))

    let path = planPath(s, 3)
    t.eqi("面包屑 3 级", path.size(), 3)
    match (path.get(0)) {
        case Some(v) => t.ok("面包屑顶层在前", containsAscii(v.toString(), "根"))
        case None => t.ok("面包屑顶层在前", false)
    }

    /* TaskBrief / TaskDetail 的派生量与隐私 */
    t6.blocker = "等场地审批"
    let brief = taskBrief(s, t6, now).toString()
    t.ok("brief: blocked=true", containsAscii(brief, "\"blocked\":true"))
    t.ok("brief: is_overdue=false", containsAscii(brief, "\"is_overdue\":false"))
    t.ok("brief: 含 overdue_days（D-5）", containsAscii(brief, "\"overdue_days\":0"))
    /*
     * P0（队友复验，2026-09-16）：阻塞原因必须进 TaskBrief。
     * 设计规格 P01 的「阻塞中」卡片直接渲染阻塞原因高亮块；原先 blocker 只在 TaskDetail 里，
     * 首页要显示它就得为每张卡再打一次详情接口。
     */
    t.ok("brief: 阻塞原因进 TaskBrief（P0 复验）", containsAscii(brief, "等场地审批"))
    t.ok("brief: 非阻塞任务 blocker=null（P0 复验）",
        containsAscii(taskBrief(s, t1, now).toString(), "\"blocker\":null"))
    t.ok("brief: 无求助对象时 needs_help=null（D-4）", containsAscii(brief, "\"needs_help\":null"))
    t.ok("brief: 不含手机号", !containsAscii(brief, "\"phone\""))
    /*
     * D-4：求助对象 = 部门 + 人（设计规格 P03「需要帮助 · 宣传部 陈屿」）。
     * 回退到"没有 needs_help 字段"时这三条会一起变红。
     */
    let helpDept = Department()
    helpDept.id = 3
    helpDept.name = "宣传部"
    s.departments[3] = helpDept
    let helper = mkMember(other, "member", 3)
    helper.name = "陈屿"
    s.members[other] = helper
    t6.help_dept_id = 3
    t6.help_member_id = other
    let briefHelp = taskBrief(s, t6, now).toString()
    t.ok("brief: needs_help 不是 null（D-4）", !containsAscii(briefHelp, "\"needs_help\":null"))
    t.ok("brief: needs_help 含求助部门（D-4）", containsAscii(briefHelp, "宣传部"))
    t.ok("brief: needs_help 含求助人（D-4）", containsAscii(briefHelp, "陈屿"))
    /* 只到部门、不指定到人时 member 必须为 null（不是空对象） */
    t6.help_member_id = 0
    let briefDept = taskBrief(s, t6, now).toString()
    t.ok("brief: 只到部门时 member=null（D-4）", containsAscii(briefDept, "\"member\":null"))
    /* 离开 blocked 时由 handler 清空；这里钉住视图侧的语义：两者都为 0 → null */
    t6.help_dept_id = 0
    let briefCleared = taskBrief(s, t6, now).toString()
    t.ok("brief: 清空后 needs_help=null（D-4）", containsAscii(briefCleared, "\"needs_help\":null"))
    let detail = taskDetail(s, t6, now).toString()
    t.ok("detail 含 blocker", containsAscii(detail, "等场地审批"))
    t.ok("detail 含 plan_path", containsAscii(detail, "plan_path"))
    t.ok("detail 含 completed_at", containsAscii(detail, "completed_at"))

    /* 幂等表 */
    idemPut(s, "task", 7, "tok-1", 42, now)
    let hit1 = idemHit(s, "task", 7, "tok-1", now + 100)
    t.ok("24h 内命中", hit1.isSome())
    t.eqi("命中的是首次创建的资源", hit1 ?? -1, 42)
    t.ok("不同 kind 不串", idemHit(s, "plan", 7, "tok-1", now + 100).isNone())
    t.ok("超过 24h 失效", idemHit(s, "task", 7, "tok-1", now + 86401).isNone())
    t.ok("失效后被清理", !s.idem.contains("task:7:tok-1"))
    /* P0 H-2：幂等键必须按提交者隔离，否则乙拿甲的 client_token 重放就能读到甲的资源 */
    idemPut(s, "task", 7, "tok-shared", 42, now)
    t.ok("同一 token 换个人不命中（H-2）", idemHit(s, "task", 8, "tok-shared", now + 10).isNone())
    t.ok("本人重放仍然命中", idemHit(s, "task", 7, "tok-shared", now + 10).isSome())
}

/* ===================== Part 5 的课题 ===================== */

func planStatTotal(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.total
        case None => return -1
    }
}

func planStatDone(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.done
        case None => return -1
    }
}

func planStatOwn(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.task_count
        case None => return -1
    }
}

func planStatChild(st: HashMap<Int64, PlanStats>, id: Int64): Int64 {
    match (st.get(id)) {
        case Some(x) => return x.child_count
        case None => return -1
    }
}

func testPlans(t: TR): Unit {
    println("- plans 课题树 递归聚合 环形校验 删除上提")
    let s = Store("build/test-data-plans")
    let p1 = Plan()
    p1.id = 1
    p1.title = "P1"
    p1.parent_id = 0
    p1.dept_id = 2
    p1.owner_id = 7
    let p2 = Plan()
    p2.id = 2
    p2.title = "P2"
    p2.parent_id = 1
    p2.owner_id = 7
    let p3 = Plan()
    p3.id = 3
    p3.title = "P3"
    p3.parent_id = 2
    p3.owner_id = 8
    let p4 = Plan()
    p4.id = 4
    p4.title = "P4"
    p4.parent_id = 0
    p4.dept_id = 3
    p4.owner_id = 9
    s.plans[1] = p1
    s.plans[2] = p2
    s.plans[3] = p3
    s.plans[4] = p4

    /* dept_id 只存顶层，子课题的部门由所属根决定（规则 19） */
    t.eqi("顶层部门", planDeptOf(s, 1), 2)
    t.eqi("子课题部门看根", planDeptOf(s, 2), 2)
    t.eqi("孙课题部门看根", planDeptOf(s, 3), 2)
    t.eqi("另一棵树部门", planDeptOf(s, 4), 3)
    t.eqi("向上找到的根", planRootOf(s, 3), 1)

    /* 层级与子树高度 */
    t.eqi("顶层深度", planDepthOf(s, 1), 1)
    t.eqi("孙深度", planDepthOf(s, 3), 3)
    t.eqi("顶层子树高度", planHeightOf(s, 1), 3)
    t.eqi("中间节点子树高度", planHeightOf(s, 2), 2)
    t.eqi("叶子高度", planHeightOf(s, 3), 1)
    t.eqi("顶层直接子节点数", planChildrenOf(s, 1).size, 1)

    /* 环形校验：从目标父节点向上遍历 */
    t.ok("不能挂到自己下面", planWouldCycle(s, 1, 1))
    t.ok("不能挂到自己的后代下面", planWouldCycle(s, 1, 3))
    t.ok("挂到无关节点可以", !planWouldCycle(s, 1, 4))
    t.ok("挂到自己的父节点可以", !planWouldCycle(s, 2, 1))
    t.ok("提升为顶层不算环", !planWouldCycle(s, 2, 0))

    /* 递归聚合：1 -> 2 -> 3，任务挂在不同层级 */
    let t1 = Task()
    t1.id = 1
    t1.title = "T1"
    t1.owner_id = 7
    t1.plan_id = 1
    t1.dept_id = 2
    t1.status = "done"
    let t2 = Task()
    t2.id = 2
    t2.title = "T2"
    t2.owner_id = 7
    t2.plan_id = 2
    t2.dept_id = 2
    t2.status = "doing"
    let t3 = Task()
    t3.id = 3
    t3.title = "T3"
    t3.owner_id = 7
    t3.plan_id = 3
    t3.dept_id = 2
    t3.status = "done"
    let t4 = Task()
    t4.id = 4
    t4.title = "T4"
    t4.owner_id = 7
    t4.plan_id = 3
    t4.dept_id = 2
    t4.status = "todo"
    let t5 = Task()
    t5.id = 5
    t5.title = "T5 已删除"
    t5.owner_id = 7
    t5.plan_id = 3
    t5.dept_id = 2
    t5.status = "done"
    t5.deleted_at = 1789898400
    s.tasks[1] = t1
    s.tasks[2] = t2
    s.tasks[3] = t3
    s.tasks[4] = t4
    s.tasks[5] = t5

    let ids = HashSet<Int64>()
    ids.add(1)
    ids.add(2)
    ids.add(3)
    let st = planStatsAll(s, ids)

    t.eqi("叶子 total 含自身", planStatTotal(st, 3), 2)
    t.eqi("叶子 done", planStatDone(st, 3), 1)
    t.eqi("叶子本级任务数 软删除不计", planStatOwn(st, 3), 2)
    t.eqi("中间节点 total 等于本级 1 加子树 2", planStatTotal(st, 2), 3)
    t.eqi("中间节点 done 等于 0 加 1", planStatDone(st, 2), 1)
    t.eqi("根 total 等于本级 1 加子树 3", planStatTotal(st, 1), 4)
    t.eqi("根 done 等于 1 加 1", planStatDone(st, 1), 2)
    t.eqi("本级任务数不含子课题", planStatOwn(st, 1), 1)
    t.eqi("根的直接子课题数", planStatChild(st, 1), 1)

    /* 删除中间节点：直接子节点上提一级 */
    let mv = planDeletePromote(s, 2)
    t.eqi("上提课题数", mv[0], 1)
    t.eqi("上提任务数", mv[1], 1)
    t.ok("被删课题已移除", !s.plans.contains(2))
    match (s.plans.get(3)) {
        case Some(x) => t.eqi("孙课题上提到根下", x.parent_id, 1)
        case None => t.ok("孙课题还在", false)
    }
    match (s.tasks.get(2)) {
        case Some(x) => t.eqi("本级任务上提到根下", x.plan_id, 1)
        case None => t.ok("任务还在", false)
    }

    /* 删除顶层：子课题变顶层并继承部门，孙节点不动 */
    let p5 = Plan()
    p5.id = 5
    p5.title = "P5"
    p5.parent_id = 0
    p5.dept_id = 3
    p5.owner_id = 9
    let p6 = Plan()
    p6.id = 6
    p6.title = "P6"
    p6.parent_id = 5
    p6.owner_id = 9
    let p7 = Plan()
    p7.id = 7
    p7.title = "P7"
    p7.parent_id = 6
    p7.owner_id = 9
    s.plans[5] = p5
    s.plans[6] = p6
    s.plans[7] = p7
    let t6 = Task()
    t6.id = 6
    t6.title = "T6"
    t6.owner_id = 9
    t6.plan_id = 5
    t6.dept_id = 3
    t6.status = "todo"
    s.tasks[6] = t6

    let mv2 = planDeletePromote(s, 5)
    t.eqi("删除顶层 上提 1 个子课题", mv2[0], 1)
    t.eqi("删除顶层 上提 1 个任务", mv2[1], 1)
    match (s.plans.get(6)) {
        case Some(x) =>
            t.eqi("子课题变为顶层", x.parent_id, 0)
            t.eqi("子课题继承原根的部门", x.dept_id, 3)
        case None => t.ok("子课题还在", false)
    }
    match (s.plans.get(7)) {
        case Some(x) => t.eqi("孙节点不被上提 父仍是 6", x.parent_id, 6)
        case None => t.ok("孙节点还在", false)
    }
    match (s.tasks.get(6)) {
        case Some(x) => t.eqi("顶层被删 本级任务变独立", x.plan_id, 0)
        case None => t.ok("任务还在", false)
    }
}

/* ===================== 注册口令节流（N-6） ===================== */

func testRegThrottle(t: TR): Unit {
    println("- auth 注册口令节流（按 IP + 递增退避）")
    let dir = "test-data-regthrottle"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = storeLoad(dir)
    let now = nowEpoch()

    /* 同一 IP 错 9 次还没锁，第 10 次触发锁定 */
    var i: Int64 = 0
    while (i < REG_FAIL_LIMIT - 1) {
        regFailBump(s, "10.0.0.1")
        i += 1
    }
    t.ok("错 9 次还没锁", !regLocked(s, "10.0.0.1", now))
    regFailBump(s, "10.0.0.1")
    t.ok("第 10 次触发锁定", regLocked(s, "10.0.0.1", now))

    /* 另一个 IP 完全不受影响 —— 这正是与旧全局锁最关键的区别（N-6 的核心收益） */
    t.ok("另一个 IP 不受影响", !regLocked(s, "10.0.0.2", now))
    i = 0
    while (i < REG_FAIL_LIMIT - 1) {
        regFailBump(s, "10.0.0.2")
        i += 1
    }
    t.ok("两个 IP 各数各的", !regLocked(s, "10.0.0.2", now))

    /* 递增退避：首次 5 分钟 */
    let st1 = s.reg_fail.get("10.0.0.1") ?? RegFail()
    let firstLock = st1.locked_until - now
    t.ok("首次锁 5 分钟", (firstLock >= REG_FAIL_LOCK_BASE - 2) && (firstLock <= REG_FAIL_LOCK_BASE + 2))
    t.ok("锁定期内判定为锁", regLocked(s, "10.0.0.1", now + 60))
    t.ok("锁到期自动解除", !regLocked(s, "10.0.0.1", now + REG_FAIL_LOCK_BASE + 2))

    /* 同一 IP 再触发一次 → 翻倍 */
    i = 0
    while (i < REG_FAIL_LIMIT) {
        regFailBump(s, "10.0.0.1")
        i += 1
    }
    let st2 = s.reg_fail.get("10.0.0.1") ?? RegFail()
    t.ok("第二次锁更久（翻倍）", st2.locked_until - nowEpoch() > firstLock)
    t.ok("退避有上限（1 小时）", regLockSeconds(99) == REG_FAIL_LOCK_MAX)

    /* 注册成功会清掉该 IP 的失败状态 */
    s.reg_fail.remove("10.0.0.1")
    t.ok("成功后该 IP 不再被锁", !regLocked(s, "10.0.0.1", nowEpoch()))

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/* ===================== 轻舟 RBAC 适配层（本地适配，非上游原版） ===================== */

/*
 * 覆盖 server/src/fw_rbac_store.cj + fw_rbac.cj：轻舟升级后新增的 RBAC 数据层与授权中间件，
 * 因沧海 CangDB 1.0.5 与 cjc 1.1.3 不兼容（编译通过、运行超时）而由我们适配（数据层 = 文件存储、响应 = 我们的错误格式）。
 * 这里测的是"适配后的行为与上游语义一致"，重点是**落盘往返**（换成文件存储后的关键差异）。
 */
func testRbacAdaptation(t: TR): Unit {
    println("- 轻舟 RbacStore 适配版（文件存储，无 CangDB）")
    let dir = "test-data-rbac"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let path = "${dir}/rbac.json"
    let st = RbacStore(path)

    /* 种子数据与上游一致：2 个角色、6 个权限、2 个账号 */
    t.eqi("角色数=2", st.listRoles().size, 2)
    t.eqi("权限数=6", st.listPermissions().size, 6)
    t.eqi("用户数=2", st.listUsers().size, 2)
    t.eqs("角色名 admin", st.roleNameOf(1), "admin")
    t.eqs("不存在的角色名=空", st.roleNameOf(99), "")

    /* RBAC 链：用户 -> 角色 -> 权限（分步查询 + 应用层组合，与上游同口径） */
    t.ok("admin 有 user:list", st.hasPermission(1, "user:list"))
    t.ok("admin 有 dashboard:view", st.hasPermission(1, "dashboard:view"))
    t.ok("user 没有 user:list", !st.hasPermission(2, "user:list"))
    t.ok("user 有 dashboard:view", st.hasPermission(2, "dashboard:view"))
    t.eqi("admin 权限码 6 个", st.permissionCodesOf(1).size, 6)
    t.eqi("user 权限码 1 个", st.permissionCodesOf(2).size, 1)
    t.ok("不存在的用户无权限", !st.hasPermission(99, "user:list"))

    match (st.findUserByUsername("admin")) {
        case Some(u) => t.eqi("admin 的角色 id", u.roleId, 1)
        case None => t.ok("admin 存在", false)
    }
    t.ok("不存在的用户名 -> None", st.findUserByUsername("nobody").isNone())
    t.ok("按 id 查得到", st.findUserById(2).isSome())

    /* 落盘往返：换成文件存储后最关键的一条 —— 重开后数据必须还在 */
    let newId = st.createUser("tester", hashPassword("pw123456", "salt", 10), 2)
    t.ok("新用户 id 递增", newId > 2)
    st.close()

    let st2 = RbacStore(path)
    t.ok("重开后新用户还在", st2.findUserByUsername("tester").isSome())
    t.eqi("重开后用户数=3", st2.listUsers().size, 3)
    t.ok("重开后权限仍然正确", st2.hasPermission(1, "user:delete"))
    t.ok("删除用户返回 true", st2.deleteUser(newId))
    t.ok("重复删除返回 false", !st2.deleteUser(newId))
    st2.close()

    let st3 = RbacStore(path)
    t.eqi("删除后用户数=2", st3.listUsers().size, 2)
    st3.close()

    /*
     * 2026-09-16（读码发现的数据安全缺口）：**文件存在但内容为空时绝不能重建种子**。
     *
     * `init` 原先用 `roles.size == 0` 判"首次打开"，于是"文件在、但 roles 键缺失或为空"
     * （手工编辑过、或将来键名写错）会被当成首次打开 → seed() + save() →
     * **用户真实数据被种子覆盖**。现在判据改成"文件不存在"，此断言即其闸门。
     */
    let emptyDir = "test-data-rbac-empty"
    if (exists(emptyDir)) {
        remove(emptyDir, recursive: true)
    }
    Directory.create(emptyDir, recursive: true)
    let emptyPath = "${emptyDir}/rbac.json"
    File.writeTo(emptyPath, "{\"users\":[],\"roles\":[],\"permissions\":[],\"role_permissions\":[]}".toArray())
    let before = String.fromUtf8(File.readFrom(emptyPath))
    let stEmpty = RbacStore(emptyPath)
    let after = String.fromUtf8(File.readFrom(emptyPath))
    t.eqi("RbacStore：roles 为空的既有文件 → 不灌种子（角色数 0）", stEmpty.listRoles().size, 0)
    t.ok("RbacStore：roles 为空的既有文件 → 内容未被覆盖", before == after)
    stEmpty.close()
    if (exists(emptyDir)) {
        remove(emptyDir, recursive: true)
    }

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 4：storeSave 只在锁内取快照，写盘由 snapshotFlush 中间件在锁外完成。
 * 这里直接验证这条两段式契约本身（HTTP 层的端到端验证在冒烟测试 [24] 重启持久性里）：
 *   · storeSave 之后磁盘上**还没有**新数据 → 证明整库 IO 确实不在锁内那一段
 *   · pending 里已有完整快照，flushPending 之后磁盘上就有了
 *   · 没有待写快照时 flushPending 是空操作（幂等）
 *   · 序号守卫：并发写盘收敛到最新版本，旧快照不会覆盖新快照
 */
func testDeferredSave(t: TR): Unit {
    println("- store 动作4：快照在锁内、写盘在锁外")
    let dir = "build/test-data-deferred"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)

    /* 新的写入入口：业务代码只写修改，锁和快照由 storeMutation 处理。 */
    let mutationStore = Store(dir + "-mutation")
    let changedName = storeMutation(mutationStore, { =>
        let md = Department()
        md.id = 1
        md.name = "事务测试部门"
        mutationStore.departments[1] = md
        md.name
    })
    t.eqs("storeMutation 返回业务结果", changedName, "事务测试部门")
    t.ok("storeMutation 会准备待写快照", mutationStore.pending.isSome())
    flushPending(mutationStore)
    let mutationLoaded = storeLoad(dir + "-mutation")
    t.eqi("storeMutation 的修改能加载回来", mutationLoaded.departments.size, 1)
    if (exists(dir + "-mutation")) {
        remove(dir + "-mutation", recursive: true)
    }

    let d = Department()
    d.id = 1
    d.name = "秘书处"
    s.departments[1] = d

    /* 第一段：锁内只取快照 —— 磁盘上不该有任何东西 */
    storeSave(s)
    t.ok("storeSave 后 pending 里有快照", s.pending.isSome())
    t.ok("storeSave 后**还没写盘**（IO 已移出锁内那一段）", !exists(s.dbFile()))

    /* 第二段：锁外写盘 */
    flushPending(s)
    t.ok("flushPending 后 db.json 已生成", exists(s.dbFile()))
    t.ok("flushPending 清空 pending", s.pending.isNone())
    let text = String.fromUtf8(File.readFrom(s.dbFile()))
    t.ok("落盘内容含本次变更", containsAscii(text, "秘书处"))

    /* 幂等：没有待写快照时是空操作，不碰文件 */
    flushPending(s)
    t.eqs("无待写快照时 flushPending 不改文件", String.fromUtf8(File.readFrom(s.dbFile())), text)
    t.ok("tmp 已清理", !exists(s.dbFile() + ".tmp"))

    /* 序号守卫：拿旧快照后写，不能把更新的版本覆盖回去 */
    let oldSnap = storeSnapshot(s)
    let newSnap = storeSnapshot(s)
    /*
     * S-2 契约（2026-10-04）：两种后端各带各的那份快照 ——
     *   · 文件后端 → `text`（整库 JSON 文本），`entities` 必须为空；
     *   · MySQL 后端 → `entities`（锁内取好的值语义拷贝），`text` 为空。
     * 这里钉住文件这一侧（MySQL 那侧的闸门在 testMysqlRoundTrip，需要 DSN）。
     */
    t.ok("文件后端的快照只带 text（entities 为空）", oldSnap.entities.isNone())
    t.ok("文件后端的快照带上了整库文本", oldSnap.text.size > 0)
    writeSnapshot(s, newSnap)
    writeSnapshot(s, oldSnap)
    t.eqi("旧快照被序号守卫拦住（saved_seq 不倒退）", s.saved_seq, newSnap.seq)
    t.ok("seq 单调递增", newSnap.seq > oldSnap.seq)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 3：签发令牌时顺手回收过期令牌（auth.cj 的 pruneTokens）。
 * 回归点：原先 tokens 表**只增不减**（只有"某个已过期令牌被再次使用"才会删掉它），
 * 用户不再登录就永远留着，而每次写盘都要把整表序列化进 db.json。
 */
func testTokenPrune(t: TR): Unit {
    println("- auth 令牌回收（动作3）")
    let dir = "build/test-data-prune"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)
    let now: Int64 = 1789898400
    /* 用 2286 年当"永不过期"，避免测试依赖真实时钟（issueToken 内部会取 nowEpoch）。
     * 2026-09-16 订正：原先写的是 9999999999999（13 个 9，约公元 318857 年），
     * 与注释里的 2286 年对不上，而且超出了 .NET DateTimeOffset 的表示范围 ——
     * 本项目的时间换算虽是自实现、跑得动，但一个"注释说 2286、实际是 31 万年"的常量
     * 迟早会误导人。10 个 9 = 9999999999 ≈ 2286-11-21，才是注释说的那个值。 */
    let far = 9999999999

    for (i in 1..=3) {
        let r = TokenRecord()
        r.member_id = 1
        r.created_at = now - 100000
        r.expires_at = now - i
        s.tokens["expired-${i}"] = r
    }
    for (i in 1..=2) {
        let r = TokenRecord()
        r.member_id = 1
        r.created_at = now
        r.expires_at = far
        s.tokens["live-${i}"] = r
    }

    t.eqi("回收前 5 条", s.tokens.size, 5)
    t.eqi("回收了 3 条过期令牌", pruneTokens(s, now), 3)
    t.eqi("剩下 2 条活跃令牌", s.tokens.size, 2)
    t.ok("过期令牌已删除", !s.tokens.contains("expired-1"))
    t.ok("活跃令牌保留", s.tokens.contains("live-1"))

    /* 没有过期令牌时是空操作 */
    t.eqi("无过期令牌时返回 0", pruneTokens(s, now), 0)
    t.eqi("无过期令牌时表大小不变", s.tokens.size, 2)

    /* 真正的调用点：issueToken 会顺手回收（1970 年到期，任何真实时钟下都算过期） */
    let dead = TokenRecord()
    dead.member_id = 1
    dead.created_at = 1
    dead.expires_at = 1
    s.tokens["expired-later"] = dead
    let issued = issueToken(s, 7)
    t.ok("新令牌已签发", s.tokens.contains(issued[0]))
    t.ok("issueToken 顺手回收了过期令牌", !s.tokens.contains("expired-later"))
    t.eqi("表大小 = 2 活跃 + 1 新", s.tokens.size, 3)

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * 容量基准动作 1：sortByKey 由插入排序换成堆排序（store.cj）。
 * 复杂度是性能属性、不适合在单测里断言时间；这里守住的是**换实现不能换语义**：
 * 逆序输入、同键输入、单元素、空数组四个边界。
 */
func testSortEdge(t: TR): Unit {
    println("- sort 堆排序边界（动作1）")
    let n = 500
    let arr = ArrayList<Task>()
    var i = n
    while (i > 0) {
        let x = Task()
        x.id = i
        x.title = "T${i}"
        /* 确定性乱序：7919 与 100000 互质，键与 id 顺序完全错开 */
        x.due_at = (i * 7919) % 100000
        arr.add(x)
        i -= 1
    }
    let out = sortedTasksByDue(arr)
    t.eqi("元素一个不少", out.size, n)
    var ordered = true
    var j = 1
    while (j < out.size) {
        if (out[j - 1].due_at > out[j].due_at) {
            ordered = false
        }
        j += 1
    }
    t.ok("500 条乱序输入排成升序", ordered)
    /* 键含 id，同 due_at 也必须是全序（不会因不稳定而乱） */
    var strict = true
    j = 1
    while (j < out.size) {
        if (out[j - 1].due_at == out[j].due_at && out[j - 1].id >= out[j].id) {
            strict = false
        }
        j += 1
    }
    t.ok("同截止时间按 id 兜底", strict)

    /* 全部同键：仍然不丢元素、按 id 升序 */
    let same = ArrayList<Task>()
    var k: Int64 = 100
    while (k > 0) {
        let x = Task()
        x.id = k
        x.due_at = 5000
        same.add(x)
        k -= 1
    }
    let out2 = sortedTasksByDue(same)
    t.eqi("同键元素数不变", out2.size, 100)
    t.eqi("同键首元素是最小 id", out2[0].id, 1)
    t.eqi("同键末元素是最大 id", out2[99].id, 100)

    /* 真实截止时间可到 9999 年，不能被有限哨兵排到 no_due 后面。 */
    let farFuture = ArrayList<Task>()
    let far = Task()
    far.id = 1
    far.due_at = parseIso("9999-12-31T00:00:00+08:00") ?? 0
    let none = Task()
    none.id = 2
    none.due_at = 0
    farFuture.add(none)
    farFuture.add(far)
    let farOut = sortedTasksByDue(farFuture)
    t.eqi("9999 年截止仍排在无截止之前", farOut[0].id, 1)
    t.eqi("无截止仍排最后", farOut[1].id, 2)

    /* 边界：单元素 / 空数组 */
    let one = ArrayList<Task>()
    let only = Task()
    only.id = 9
    only.due_at = 1
    one.add(only)
    t.eqi("单元素原样返回", sortedTasksByDue(one).size, 1)
    t.eqi("空数组返回空", sortedTasksByDue(ArrayList<Task>()).size, 0)
}

/*
 * N-14：本机判定的回归闸门。
 *
 * 用纯函数 `isLoopbackPeer` 覆盖各种对端文本 —— 冒烟测试只能从本机发包，
 * 造不出"远程 IPv6 对端"，所以**反例只能落在单测里**（第四轮评测 §四专门指出
 * /admin/shutdown 只有正例，N-14 正是从这里逃逸的）。
 * 下面"不是本机"那几条正是老实现（`containsAscii(p, "::1")`）会误判的输入。
 */
func testLoopbackPeer(t: TR): Unit {
    println("- 本机判定（N-14）")
    /* 真回环：各种写法都要放行 */
    t.ok("[::1]:5000 是本机", isLoopbackPeer("[::1]:5000"))
    t.ok("[127.0.0.1]:5000 是本机", isLoopbackPeer("[127.0.0.1]:5000"))
    t.ok("127.0.0.1:5000 是本机", isLoopbackPeer("127.0.0.1:5000"))
    t.ok("裸 ::1 是本机", isLoopbackPeer("::1"))
    t.ok("[0:0:0:0:0:0:0:1]:5000 是本机（全展开）", isLoopbackPeer("[0:0:0:0:0:0:0:1]:5000"))
    t.ok("[::ffff:127.0.0.1]:5000 是本机（IPv4 映射）", isLoopbackPeer("[::ffff:127.0.0.1]:5000"))

    /* 远程 —— 这些在"子串匹配 ::1"的老实现下**全部为 true**（N-14 的漏洞面） */
    t.ok("[2001:db8::1]:5000 不是本机", !isLoopbackPeer("[2001:db8::1]:5000"))
    t.ok("[fe80::1a2b:3c4d:5e6f]:5000 不是本机", !isLoopbackPeer("[fe80::1a2b:3c4d:5e6f]:5000"))
    t.ok("[fd00::1]:5000 不是本机", !isLoopbackPeer("[fd00::1]:5000"))
    t.ok("[2001:db8::1000]:5000 不是本机", !isLoopbackPeer("[2001:db8::1000]:5000"))
    t.ok("[2001:db8::abcd]:5000 不是本机", !isLoopbackPeer("[2001:db8::abcd]:5000"))
    t.ok("100.64.0.9:5000 不是本机", !isLoopbackPeer("100.64.0.9:5000"))
    t.ok("空串不是本机", !isLoopbackPeer(""))
    t.ok("localhost 不再被当作本机（socket 对端是地址，不是主机名）", !isLoopbackPeer("localhost:5000"))

    /* 顺带盯住 N-12：裸 IPv6 不再被切成 ":" 之类的垃圾 key */
    t.eqs("裸 IPv6 整串即地址", ipOfPeerText("::1"), "::1")
    t.eqs("方括号 IPv6 取括号内", ipOfPeerText("[2001:db8::1]:5000"), "2001:db8::1")
    t.eqs("IPv4 带端口切掉端口", ipOfPeerText("127.0.0.1:14764"), "127.0.0.1")
    t.eqs("裸 IPv4 原样返回", ipOfPeerText("10.0.0.7"), "10.0.0.7")
    t.eqs("空串原样返回空", ipOfPeerText(""), "")
}

/*
 * N-16：登录材料选择的回归闸门。
 *
 * 手机号不存在时也必须拿到**等价成本**的材料。一旦有人改回"不存在就跳过 PBKDF2"，
 * 返回值会退化成空串 / 0 次迭代，这里立刻变红。
 * （"响应时间相等"本身会 flaky，不写进测试；时间表靠手工复测，见 code-review 第四轮。）
 */
func testLoginCreds(t: TR): Unit {
    println("- 登录口令材料（N-16）")
    let real = loginCreds(true, "aabbccdd", "eeff0011", 100000)
    t.eqs("号码存在：用真实盐", real[0], "aabbccdd")
    t.eqs("号码存在：用真实摘要", real[1], "eeff0011")
    t.eqi("号码存在：用真实迭代数", real[2], 100000)

    let dummy = loginCreds(false, "aabbccdd", "eeff0011", 1)
    t.ok("号码不存在：盐非空（会真的算）", dummy[0].size > 0)
    t.ok("号码不存在：摘要非空", dummy[1].size > 0)
    t.ok("号码不存在：不泄露真实盐", dummy[0] != "aabbccdd")
    t.ok("号码不存在：不泄露真实摘要", dummy[1] != "eeff0011")
    t.eqi("号码不存在：迭代数取标准值", dummy[2], PBKDF2_ITER)
    t.eqi("两条路径迭代数相同（成本等价）", dummy[2], real[2])
    /* 弱形式：假材料格式合法，能真正走完一遍 PBKDF2（不会因格式错误提前返回） */
    t.ok("假材料能走完 PBKDF2（口令不匹配）", !verifyPw("whatever123", dummy[0], dummy[1], dummy[2]))
}

/*
 * N-17：审计行"锁内只挂缓冲、锁外才落盘"的回归闸门。
 * audit() 不碰磁盘；flushPending()（请求链末端、已解锁）才 append。
 */
func testAuditDeferred(t: TR): Unit {
    println("- 审计行锁外落盘（N-17）")
    let dir = "build/test-data-audit"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let s = Store(dir)
    audit(s, 1, "reset-password", 2, "note\twith\ttabs\nand-a-forged-line")
    t.eqi("audit() 只挂缓冲", s.audit_pending.size, 1)
    t.ok("audit() 没有立刻写文件（锁内不做 IO）", !exists("${dir}/audit.log"))

    flushPending(s)
    t.ok("flushPending 之后审计落盘", exists("${dir}/audit.log"))
    t.eqi("缓冲已清空", s.audit_pending.size, 0)
    let text = String.fromUtf8(File.readFrom("${dir}/audit.log"))
    t.ok("含动作名", containsAscii(text, "reset-password"))
    t.ok("含 target", containsAscii(text, "target=2"))
    var nl = 0
    for (b in text.toArray()) {
        if (b == 10) {
            nl += 1
        }
    }
    t.eqi("注入的换行没伪造出第二条记录（L-9 仍生效）", nl, 1)
    t.ok("制表符被替换成空格", !containsAscii(text, "note\twith"))

    /* 审计缓冲是内存态，绝不能进 db.json */
    storeSaveNow(s)
    let db = String.fromUtf8(File.readFrom(s.dbFile()))
    t.ok("audit_pending 不落盘", !containsAscii(db, "audit_pending"))

    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

/*
 * PBKDF2 并发闸门（N-21）—— 应用层**唯一**的减载手段。
 *
 * 2026-09-18：原先这里还断言登录的**按 IP** 节流（计数、锁定、另一个 IP 不受影响）。
 * 那条按 IP 的节流已按"应用层不做抗 DDoS"的口径移除：它挡不住分布式，
 * 且在 NAT / 校园网出口下会把整个社团一起锁在外面 —— 流量层的事交给网络侧。
 * 现在只钉住"与来源无关"的这一道：到上限就拒（429）、不排队、释放后可再进。
 */
func testPbkdf2Gate(t: TR): Unit {
    println("- PBKDF2 并发闸门（N-21，应用层唯一的减载手段）")
    let s = Store("build/test-data-n21")

    /* 1) 到上限就拒（不排队），释放后可再进 */
    var got: Int64 = 0
    var k: Int64 = 0
    while (k < MAX_PBKDF2_INFLIGHT) {
        if (pbkdf2Enter(s)) {
            got += 1
        }
        k += 1
    }
    t.eqi("上限内全部放行", got, MAX_PBKDF2_INFLIGHT)
    t.ok("超过上限被拒（不排队）", !pbkdf2Enter(s))
    t.eqi("在跑计数 = 上限", s.pbkdf2_inflight, MAX_PBKDF2_INFLIGHT)
    pbkdf2Leave(s)
    t.ok("释放一个后可以再进", pbkdf2Enter(s))

    /* 2) 多释放也不会把计数弄成负数（异常路径的安全网） */
    var m: Int64 = 0
    while (m < MAX_PBKDF2_INFLIGHT + 3) {
        pbkdf2Leave(s)
        m += 1
    }
    t.eqi("多释放不会变负", s.pbkdf2_inflight, 0)
}

/*
 * 输入上限（limits.cj，2026-09-17）。
 *
 * 这些常量是"库别被单条记录撑爆"的保险丝：每个字段都整份进 db.json，而**每次写都要
 * 重写整个库**（约 3 倍文件大小的 IO）。所以这里钉住三件事：
 *   ① 收集器版（lenCheck）确实把超长记成**字段级**错误（表单要能一次报齐）；
 *   ② 立即版（requireLen）超长时抛的是 ApiError 且 code 是 VALIDATION_FAILED；
 *   ③ 边界口径是"**大于**上限才拒"（等于上限放行）—— 将来有人把 `>` 写成 `>=`，这条会红。
 * 另外钉住"中文按字节算"（`String.size` 是字节数，一个中文 3 字节），
 * 这与 passwordLenError 是同一口径。
 */
func testLimits(t: TR): Unit {
    println("- limits 输入上限（请求体 / 文本字段）")
    let v = V()
    lenCheck(v, "title", "标题", "abcd", 4)
    t.eqi("等于上限：不收错", v.bad, 0)
    lenCheck(v, "title", "标题", "abcde", 4)
    t.eqi("超一字节：收一个错", v.bad, 1)
    var msg = ""
    match (jsonGetStr(v.fields, "title")) {
        case Some(x) => msg = x
        case None => ()
    }
    t.ok("字段级提示里带上限数字", containsAscii(msg, "4"))

    var threwCode = ""
    try {
        requireLen("desc", "描述", "abcde", 4)
    } catch (e: ApiError) {
        threwCode = e.code
    }
    t.eqs("requireLen 超长抛 VALIDATION_FAILED", threwCode, "VALIDATION_FAILED")
    var noThrow = true
    try {
        requireLen("desc", "描述", "abcd", 4)
    } catch (e: ApiError) {
        noThrow = false
    }
    t.ok("requireLen 等于上限不抛", noThrow)

    let v2 = V()
    lenCheck(v2, "name", "姓名", "张三", 5)
    t.eqi("两个中文（6 字节）超过 5 字节上限", v2.bad, 1)

    /* 常量本身：被改成 0 / 负数会让所有写请求都 400，那是比"没上限"更糟的故障 */
    t.ok("请求体上限是正数且不小于 16 KiB", MAX_BODY_BYTES >= 16 * 1024)
    t.ok("五个文本上限都是正数", MAX_TITLE_BYTES > 0 && MAX_DESC_BYTES > 0 && MAX_BLOCKER_BYTES > 0 &&
        MAX_NAME_BYTES > 0 && MAX_CLIENT_TOKEN_BYTES > 0)
}

/* 请求字段存在但类型错误时必须返回校验错误，不能静默当成缺失字段。 */
func testRequestJsonTypes(t: TR): Unit {
    println("- 请求 JSON 字段类型校验（S-4）")

    let badStr = JsonObject()
    badStr.put("title", JsonInt(123))
    var strCode = ""
    try {
        reqStrOr(badStr, "title", "")
    } catch (e: ApiError) {
        strCode = e.code
    }
    t.eqs("字符串字段类型错误 -> VALIDATION_FAILED", strCode, "VALIDATION_FAILED")

    let badInt = JsonObject()
    badInt.put("owner_id", JsonString("7"))
    var intCode = ""
    try {
        reqIntOr(badInt, "owner_id", 0)
    } catch (e: ApiError) {
        intCode = e.code
    }
    t.eqs("整数字段类型错误 -> VALIDATION_FAILED", intCode, "VALIDATION_FAILED")

    let badTime = JsonObject()
    badTime.put("due_at", JsonInt(123))
    var timeCode = ""
    try {
        reqTime(badTime, "due_at")
    } catch (e: ApiError) {
        timeCode = e.code
    }
    t.eqs("时间字段类型错误 -> VALIDATION_FAILED", timeCode, "VALIDATION_FAILED")

    let nulls = JsonObject()
    nulls.put("title", JsonNull())
    nulls.put("owner_id", JsonNull())
    nulls.put("due_at", JsonNull())
    t.eqs("显式 null 字符串仍按缺省处理", reqStrOr(nulls, "title", ""), "")
    t.eqi("显式 null 整数仍按缺省处理", reqIntOr(nulls, "owner_id", 0), 0)
    t.eqi("显式 null 时间仍表示无截止", reqTime(nulls, "due_at"), 0)
}

/*
 * PATCH /tasks/{id} 的字段闸门（h_task.cj 的 rejectUnknownTaskFields）。
 *
 * 为什么单独钉这一条（2026-09-18 复核补测）：本闸门原先只有"具名拒绝名单"，
 * 于是 `{"foo":1}`、拼错的 `{"titel":"x"}` 仍会返回 200 且**静默忽略** ——
 * 也就是说它自称消灭的那个形态其实还在。而 `JsonObject` 不能枚举键（无 `keys()`），
 * 兜底只能靠"键数 > 白名单命中数"判定，所以这里把那个判定的两侧都钉住，
 * 含"同键重复在 HashMap 里只算一个键"这层容易写错的前提。
 */
func testTaskPatchWhitelist(t: TR): Unit {
    println("- 任务 PATCH 字段白名单（未知字段兜底）")

    let okBody = JsonObject()
    okBody.put("title", JsonString("标题"))
    okBody.put("owner_id", JsonInt(3))
    okBody.put("due_at", JsonNull())
    var okPassed = true
    try {
        rejectUnknownTaskFields(okBody)
    } catch (e: ApiError) {
        okPassed = false
    }
    t.ok("白名单字段全部放行", okPassed)

    var emptyPassed = true
    try {
        rejectUnknownTaskFields(JsonObject())
    } catch (e: ApiError) {
        emptyPassed = false
    }
    t.ok("空请求体放行（不是必须带字段）", emptyPassed)

    let dupBody = JsonObject()
    dupBody.put("title", JsonString("a"))
    dupBody.put("title", JsonString("b"))
    var dupPassed = true
    try {
        rejectUnknownTaskFields(dupBody)
    } catch (e: ApiError) {
        dupPassed = false
    }
    t.ok("同键重复不被当成未知字段", dupPassed)

    /* 拼错的字段名：原先静默忽略的那一类 */
    let typo = JsonObject()
    typo.put("titel", JsonString("标题"))
    var typoCode = ""
    var typoOnBody = false
    try {
        rejectUnknownTaskFields(typo)
    } catch (e: ApiError) {
        typoCode = e.code
        match (e.fields) {
            case Some(o) => typoOnBody = o.containsKey("body")
            case None => ()
        }
    }
    t.eqs("拼错字段名 -> VALIDATION_FAILED", typoCode, "VALIDATION_FAILED")
    t.ok("拼错字段名报在 body 上（点不出键名，只能说明接受哪些）", typoOnBody)

    /* 白名单字段 + 未知字段混用：不能因为"命中数够"就放过 */
    let mixed = JsonObject()
    mixed.put("title", JsonString("标题"))
    mixed.put("desc", JsonString("描述"))
    mixed.put("foo", JsonInt(1))
    var mixedRejected = false
    try {
        rejectUnknownTaskFields(mixed)
    } catch (e: ApiError) {
        mixedRejected = true
    }
    t.ok("白名单字段 + 未知字段混用 -> 拒", mixedRejected)

    /* 具名名单仍优先生效，给出"该走哪个接口"的具体提示 */
    let withStatus = JsonObject()
    withStatus.put("title", JsonString("标题"))
    withStatus.put("status", JsonString("done"))
    var statusOnField = false
    var statusCode = ""
    try {
        rejectUnknownTaskFields(withStatus)
    } catch (e: ApiError) {
        statusCode = e.code
        match (e.fields) {
            case Some(o) => statusOnField = o.containsKey("status")
            case None => ()
        }
    }
    t.eqs("status -> VALIDATION_FAILED", statusCode, "VALIDATION_FAILED")
    t.ok("status 报在 status 字段上（带处置提示）", statusOnField)
}

/* ===================== 入口 ===================== */

/*
 * 单测入口。
 *
 * `mysqlCfg` 是**可选**的（2026-09-20 起）：`club-server test` 不带 DSN 时它就为 None，
 * 此时只跑原来那 500+ 条（全部直接构造内存 Store，不碰任何数据库）——
 * 这是刻意的：单测不允许依赖一台在跑的外部服务器，否则"能不能编过"就变成
 * "本机有没有装数据库"。带了 DSN 就**额外**做一次 MySQL 持久化往返验证
 * （建表 → 写内存 Store → 读回内存 → 逐字段比对）。
 */
/*
 * AI 出站模块的单测（spec §10.2 的 U1–U6 / U8 / U10 / U11 + 后续几轮修的回归点）。
 *
 * 全部**离线**：无网络、无 Store、无锁 —— 只测纯函数与语义映射。
 * 这组原先一直是 0 条（三轮审查都点了这件事），所以补的时候顺便把
 * 后面几轮修过的坑也钉住（F-1 / F-6 / F-7 / R-1 / R-8 / R-9 / R-10）。
 */
func testAi(t: TR): Unit {
    println("- ai 出站语义 / 输出归一化 / 审计")

    /* ---- U1–U5：extractJson 的容错提取（降级链路的第一环） ---- */
    var u1 = false
    match (extractJson("{\"answer\":\"a\",\"basis\":[]}")) {
        case Some(_) => u1 = true
        case None => ()
    }
    t.ok("U1 合法 JSON 可提取", u1)

    var u2 = false
    match (extractJson("```json\n{\"answer\":\"a\",\"basis\":[]}\n```")) {
        case Some(s) => u2 = containsAscii(s, "answer")
        case None => ()
    }
    t.ok("U2 围栏包裹可剥离（归一化生效）", u2)

    var u3 = false
    match (extractJson("好的，建议如下：{\"answer\":\"a\",\"basis\":[]} 以上。")) {
        case Some(s) => u3 = containsAscii(s, "answer")
        case None => ()
    }
    t.ok("U3 前后带自然语言也能提取", u3)

    var u4 = true
    match (extractJson("{\"answer\":\"a\",\"basis\":[")) {
        case Some(_) => u4 = false
        case None => ()
    }
    t.ok("U4 截断 JSON 提取失败且不抛异常", u4)

    var u5 = false
    match (extractJson("{\"answer\":\"含 { 与 } 和 \\\" 引号\",\"basis\":[]}")) {
        case Some(s) => u5 = containsAscii(s, "basis")
        case None => ()
    }
    t.ok("U5 字符串内的花括号不误判配平", u5)

    /* ---- U6 / U10 / U11：结局分类与可重试性 ---- */
    t.eqs("U6 网络层失败 -> network",
          aiClassify(OutboundResponse(0, "", networkError: Some("connect refused"))), "network")
    t.eqs("U6 200 -> ok", aiClassify(OutboundResponse(200, "{}")), "ok")
    t.eqs("U10 429 -> rate_limited", aiClassify(OutboundResponse(429, "")), "rate_limited")
    t.eqs("U10 503 -> server_error", aiClassify(OutboundResponse(503, "")), "server_error")
    t.eqs("U11 401 -> http_error", aiClassify(OutboundResponse(401, "")), "http_error")
    t.eqs("R-10 自造 -413 -> too_large（与上游真实 413 可区分）",
          aiClassify(OutboundResponse(-413, "")), "too_large")

    t.ok("U10 timeout / rate_limited / server_error / network 可重试",
         aiRetryable("timeout") && aiRetryable("rate_limited") &&
         aiRetryable("server_error") && aiRetryable("network"))
    t.ok("U11 http_error（含 401 等 4xx）**不可**重试", !aiRetryable("http_error"))
    t.ok("too_large 不可重试（是我们自己拒发的）", !aiRetryable("too_large"))
    t.ok("F-7 truncated 不可重试（重试无用，且纠错语对长度截断是错误归因）", !aiRetryable("truncated"))
    t.ok("R-10 too_large 文案中立（不再甩锅服务商）", containsAscii(aiFallbackNote("too_large"), "过长"))
    t.ok("F-7 truncated 文案提示调大 token 预算", containsAscii(aiFallbackNote("truncated"), "max-tokens"))

    /* ---- U8（反向闸门）：密钥绝不能出现在对外描述 / 日志里 ---- */
    let o = AiOptions()
    o.enabled = true
    o.endpoint = "https://sk-SECRET-KEY@api.example.com/v1/chat/completions"
    o.model = "m"
    o.apiKeyFile = "k"
    let desc = aiDescribe(o)
    t.ok("U8 启动描述里不含密钥片段（反向闸门）", !containsAscii(desc, "sk-SECRET-KEY"))
    t.ok("U8 但主机名必须在（否则运维没法核对端点）", containsAscii(desc, "api.example.com"))

    /* ---- U9：insecure 模式必须在描述里显式告警 ---- */
    let oi = AiOptions()
    oi.enabled = true
    oi.endpoint = "http://127.0.0.1:1/v1/chat/completions"
    oi.model = "m"
    oi.apiKeyFile = "k"
    oi.insecureTrustAll = true
    t.ok("U9 insecure 模式在启动描述里有醒目告警", containsAscii(aiDescribe(oi), "跳过证书校验"))

    /* ---- F-6：模型给的时间串必须过 ISO 8601 形状校验（不是原样透传） ---- */
    t.ok("F-6 带时区的 ISO 8601 通过", aiIsIso8601("2026-10-20T18:00:00+08:00"))
    t.ok("F-6 UTC（Z 结尾）通过", aiIsIso8601("2026-10-20T18:00:00Z"))
    t.ok("F-6 中文描述不通过", !aiIsIso8601("明天下午"))
    t.ok("F-6 缺时区不通过", !aiIsIso8601("2026-10-20T18:00:00"))

    /* ---- R-8：AI 未配置时 handler 走 fallback 分支 ---- */
    let o2 = AiOptions()
    o2.enabled = false
    var noClient = false
    match (newAiClient(o2)) {
        case Some(_) => ()
        case None => noClient = true
    }
    t.ok("未启用 AI 时 newAiClient 返回 None（handler 据此给 fallback，不是 none）", noClient)

    /* ---- R-9：限流额度必须真的会累积并撞线 ---- */
    aiRateCheck(900001)
    aiRateCheck(900001)
    aiRateCheck(900001)
    var limited = false
    var i: Int64 = 0
    while (i < 40) {
        try {
            aiRateCheck(900001)
        } catch (e: Exception) {
            limited = true
            break
        }
        i += 1
    }
    t.ok("R-9 同一成员连打会撞到 AI_RATE_LIMITED（额度真的在累积）", limited)

    var otherOk = true
    try {
        aiRateCheck(900002)
    } catch (e: Exception) {
        otherOk = false
    }
    t.ok("限流按成员分桶（另一个成员不受影响）", otherOk)

    /* ---- F-1：零出站的结局要退还额度 ---- */
    var k: Int64 = 0
    while (k < 40) {
        aiRateRefundIfFree(900001, AiResult(AI_SOURCE_FALLBACK, JsonObject(), "x", "overloaded", 1, 0, 0))
        k += 1
    }
    var refunded = false
    try {
        aiRateCheck(900001)
        refunded = true
    } catch (e: Exception) {
        refunded = false
    }
    t.ok("F-1 overloaded 会退还额度（退还后不再 429）", refunded)

    /* ---- R-1：多成员桶不得抛（边遍历边删曾导致 500） ---- */
    var pruneOk = true
    var m: Int64 = 0
    try {
        while (m < 60) {
            aiRateCheck(910000 + m)
            m += 1
        }
    } catch (e: Exception) {
        pruneOk = false
    }
    t.ok("R-1 批量成员计数不抛异常", pruneOk)

    /*
     * T2 / T6：工具白名单与权限收敛。
     * spec §5.6 的出口判据就是这一条 ——「`dispatchTool` 的 **denied 路径有测试**」。
     */
    let st = Store("ai-tool-test")
    let toolLead = mkMember(1, "lead", 2)
    let toolMem = mkMember(2, "member", 2)
    /* ⚠ 门槛是**副会长及以上**，不是"部长及以上"：
       perms.cj 的 lead 分支是显式白名单，里面**没有** AssignPending → case _ => return false。
       我第一版把工具说明写成"需要部长及以上"，被这条测试直接抓出来
       —— 这就是 spec 要求「denied 路径必须有测试」的价值。 */
    let toolVp = mkMember(3, "vice_president", 2)
    st.members[1] = toolLead
    st.members[2] = toolMem
    st.members[3] = toolVp

    /* ① T2：未知工具一律拒 —— 模型不能发明工具 */
    let rUnknown = dispatchAiTool(st, toolLead, "drop_database", JsonObject(), 0)
    var unknownAllowed = true
    match (jsonGetBool(rUnknown, "allowed")) {
        case Some(b) => unknownAllowed = b
        case None => ()
    }
    t.ok("T2 未知工具被拒（模型不能新增工具）", !unknownAllowed)

    /* ② T6：受限工具对普通成员 denied */
    let rDenied = dispatchAiTool(st, toolMem, "list_pending_members", JsonObject(), 0)
    var deniedAllowed = true
    match (jsonGetBool(rDenied, "allowed")) {
        case Some(b) => deniedAllowed = b
        case None => ()
    }
    t.ok("T6 list_pending_members 对普通成员 denied（AssignPending 不在其权限内）", !deniedAllowed)

    /* denied 的文案要**中性**：不能告诉模型"你缺哪个权限"，否则这接口成了权限探测面 */
    var deniedPayload = ""
    match (jsonGetStr(rDenied, "payload")) {
        case Some(p) => deniedPayload = p
        case None => ()
    }
    t.ok("denied 文案中性（不泄露具体缺哪个权限）",
         deniedPayload.size > 0 && !containsAscii(deniedPayload, "AssignPending"))

    /* ③ 同一工具对**副会长**放行 —— 证明拒绝确实来自 can() 判定，而不是工具本身坏了 */
    let rOk = dispatchAiTool(st, toolVp, "list_pending_members", JsonObject(), 0)
    var vpAllowed = false
    match (jsonGetBool(rOk, "allowed")) {
        case Some(b) => vpAllowed = b
        case None => ()
    }
    t.ok("T6 同一工具对副会长放行（拒绝确实来自 can() 判定）", vpAllowed)

    /* ③b 部长**也不行** —— 门槛是副会长及以上（lead 分支白名单里没有 AssignPending） */
    let rLeadPending = dispatchAiTool(st, toolLead, "list_pending_members", JsonObject(), 0)
    var leadPendingAllowed = true
    match (jsonGetBool(rLeadPending, "allowed")) {
        case Some(b) => leadPendingAllowed = b
        case None => ()
    }
    t.ok("T6 部长对 list_pending_members 也被拒（门槛是副会长及以上）", !leadPendingAllowed)

    /* ④ 只读工具对普通成员放行 */
    let rMy = dispatchAiTool(st, toolMem, "list_my_tasks", JsonObject(), 0)
    var myAllowed = false
    match (jsonGetBool(rMy, "allowed")) {
        case Some(b) => myAllowed = b
        case None => ()
    }
    t.ok("只读工具 list_my_tasks 对普通成员放行", myAllowed)

    /* ⑤ 回灌给模型的结果必须被截断（防 prompt 膨胀撑破 maxRequestBytes） */
    var cutPayload = ""
    match (jsonGetStr(rMy, "payload")) {
        case Some(p) => cutPayload = p
        case None => ()
    }
    t.ok("工具结果不超过回灌上限（含截断保护）", cutPayload.size <= 2200)

    /* ---- P2：写工具的「提议 / 执行」两半 ---- */
    let wt = mkMember(9, "member", 2)
    let tk = Task()
    tk.id = 501
    tk.title = "写工具测试任务"
    tk.owner_id = 9
    tk.dept_id = 2
    tk.created_by = 9
    tk.status = "todo"
    let wtStore = Store("ai-write-test")
    wtStore.members[9] = wt
    wtStore.tasks[501] = tk

    let wArgs = JsonObject()
    jPutInt(wArgs, "task_id", 501)
    jPutStr(wArgs, "status", "doing")
    var propOk = false
    match (aiToolPropose(wtStore, wt, "set_my_task_status", wArgs, 1000)) {
        case Some(_) => propOk = true
        case None => ()
    }
    t.ok("P2 写工具能产出提议", propOk)
    /* ★ 关键：提议**不得**改动任何东西 —— 否则"提议"就已经是副作用了 */
    t.eqs("P2 提议不落库（提出后任务状态未变）", tk.status, "todo")

    let wR = aiToolExecute(wtStore, wt, "set_my_task_status", wArgs, 1000)
    t.ok("P2 确认后执行成功", wR[0])
    t.eqs("P2 执行真的改了状态", tk.status, "doing")
    t.eqi("P2 执行返回资源 id", wR[1], 501)

    /* blocked 缺 blocker：必须被**业务规则**拦住（走共享的 taskStatusApply，不是工具自己判） */
    let wBad = JsonObject()
    jPutInt(wBad, "task_id", 501)
    jPutStr(wBad, "status", "blocked")
    let wRBad = aiToolExecute(wtStore, wt, "set_my_task_status", wBad, 1000)
    t.ok("P2 blocked 缺 blocker 被执行层拒（共享规则生效）", !wRBad[0])
    t.eqs("P2 被拒后状态未被改动", tk.status, "doing")

    /* TOCTOU：提议之后把角色降级，执行必须失败（执行时**重新**跑 can()） */
    wt.role = ""
    let wRAfter = aiToolExecute(wtStore, wt, "set_my_task_status", wArgs, 1000)
    t.ok("P2 TOCTOU：降级后执行被拒（执行时重新授权）", !wRAfter[0])

    /* ---- P2：确认令牌的生命周期（G1 绑定 / G2 一次性 / 过期） ---- */
    let pt = Store("ai-prop-test")
    let tok = aiProposalNew(pt, 7, "{\"tool\":\"set_my_task_status\",\"args\":{\"task_id\":501}}", 5000)
    t.ok("令牌带 ap_ 前缀（日志/审计里一眼可辨）", containsAscii(tok, "ap_"))
    var g1 = false
    match (aiProposalGet(pt, 7, tok)) {
        case Some(_) => g1 = true
        case None => ()
    }
    t.ok("G1 本人能取到自己的令牌", g1)
    var cross = false
    match (aiProposalGet(pt, 8, tok)) {
        case Some(_) => cross = true
        case None => ()
    }
    t.ok("G1 跨用户取不到（key 里含 actorId）", !cross)

    /* 未消费时 used_at 必须是 0 —— 这是"能否执行"的判据 */
    var beforeUse = -1
    var createdAt = 0
    match (aiProposalGet(pt, 7, tok)) {
        case Some(r) =>
            beforeUse = r.used_at
            createdAt = r.created_at
        case None => ()
    }
    t.eqi("G2 未消费时 used_at = 0", beforeUse, 0)
    t.eqi("提议时间戳被记下（过期判据）", createdAt, 5000)
    /* 过期窗口是 5 分钟，而 IDEM_TTL 是 24 小时 —— 必须自己判 */
    t.ok("P2 5 分钟后即过期", (5000 + AI_PROP_TTL + 1) - createdAt > AI_PROP_TTL)
    t.ok("P2 4 分钟时仍有效", (5000 + 240) - createdAt <= AI_PROP_TTL)

    aiProposalConsume(pt, 7, tok, 501, 5001)
    var afterUse = 0
    match (aiProposalGet(pt, 7, tok)) {
        case Some(r) => afterUse = r.used_at
        case None => ()
    }
    t.ok("G2 消费后 used_at 被标记（重放判据）", afterUse > 0)
    /* 令牌标签只取前 8 位 —— 日志里不该有完整令牌 */
    t.ok("令牌标签只暴露前 8 位", aiPropTag(tok).size <= 8)

    /*
     * §7.5 邀请风控：**规则兜底**的三档口径。
     * 兜底必须自洽（spec D2：兜底不得为空）—— 模型不可用时用户看到的必须是这个。
     */
    let fInvite = RiskFacts()
    fInvite.pendingTotal = 1
    fInvite.sameWindow = 1
    fInvite.fromInvite = true
    let fPair = RiskFacts()
    fPair.pendingTotal = 2
    fPair.sameWindow = 2
    fPair.fromInvite = true
    let fNoInvite = RiskFacts()
    fNoInvite.pendingTotal = 1
    fNoInvite.sameWindow = 1
    fNoInvite.fromInvite = false
    let fFlood = RiskFacts()
    fFlood.pendingTotal = 4
    fFlood.sameWindow = 3
    fFlood.fromInvite = false

    var lv1 = ""
    match (jsonGetStr(aiRiskFallback(fInvite), "level")) {
        case Some(v) => lv1 = v
        case None => ()
    }
    t.eqs("风控兜底 low：有招募链接且无扎堆", lv1, "low")
    var lv2 = ""
    match (jsonGetStr(aiRiskFallback(fPair), "level")) {
        case Some(v) => lv2 = v
        case None => ()
    }
    t.eqs("风控兜底 medium：同窗口 2 人扎堆", lv2, "medium")
    var lv3 = ""
    match (jsonGetStr(aiRiskFallback(fNoInvite), "level")) {
        case Some(v) => lv3 = v
        case None => ()
    }
    t.eqs("风控兜底 medium：没有招募链接来源", lv3, "medium")
    let rFlood = aiRiskFallback(fFlood)
    var lv4 = ""
    match (jsonGetStr(rFlood, "level")) {
        case Some(v) => lv4 = v
        case None => ()
    }
    t.eqs("风控兜底 high：同窗口 3 人扎堆且无邀请", lv4, "high")
    /* 兜底不得为空：reasons 必须有内容（spec D2） */
    var fbReasonCount: Int64 = 0
    match (jsonGetArray(rFlood, "reasons")) {
        case Some(a) => fbReasonCount = a.size()
        case None => ()
    }
    t.ok("风控兜底的 reasons 非空（D2：兜底不得为空）", fbReasonCount >= 1)
    var fbSrc = ""
    match (jsonGetStr(rFlood, "source")) {
        case Some(v) => fbSrc = v
        case None => ()
    }
    t.eqs("风控兜底的 source=fallback", fbSrc, AI_SOURCE_FALLBACK)

    /* 排序：high 必须排在前面（**只影响呈现，不影响审批动作**） */
    t.ok("风控排序 high 优先于 medium", aiRiskRank(aiRiskFallback(fFlood)) < aiRiskRank(aiRiskFallback(fPair)))
    t.ok("风控排序 medium 优先于 low", aiRiskRank(aiRiskFallback(fPair)) < aiRiskRank(aiRiskFallback(fInvite)))

    /*
     * 模型输出的**采信门槛**：这两条是防"误导用户"的核心。
     * 一个没有依据的"高风险"比不报还糟 —— 用户会去处理一个不存在的问题。
     */
    let mBad = JsonObject()
    jPutStr(mBad, "level", "weird")
    let mBadR = JsonArray()
    mBadR.add(JsonString("随便说点什么"))
    mBad.put("reasons", mBadR)
    var badLevelRejected = true
    match (aiRiskFromModel(mBad, fInvite)) {
        case Some(_) => badLevelRejected = false
        case None => ()
    }
    t.ok("风控：非法 level（不在 low/medium/high）不被采信", badLevelRejected)

    let mNoReason = JsonObject()
    jPutStr(mNoReason, "level", "high")
    mNoReason.put("reasons", JsonArray())
    var noReasonRejected = true
    match (aiRiskFromModel(mNoReason, fInvite)) {
        case Some(_) => noReasonRejected = false
        case None => ()
    }
    t.ok("风控：**没有理由的分档不被采信**（回落规则兜底）", noReasonRejected)

    let mOk = JsonObject()
    jPutStr(mOk, "level", "high")
    let mOkR = JsonArray()
    mOkR.add(JsonString("同一时段 3 人扎堆申请"))
    mOk.put("reasons", mOkR)
    var okAccepted = false
    var okSrc = ""
    match (aiRiskFromModel(mOk, fInvite)) {
        case Some(v) =>
            okAccepted = true
            match (jsonGetStr(v, "source")) {
                case Some(s) => okSrc = s
                case None => ()
            }
        case None => ()
    }
    t.ok("风控：合法且有理由的分档被采信", okAccepted)
    t.eqs("风控：采信后 source=model", okSrc, AI_SOURCE_MODEL)

    /*
     * 兜底答案**必须自述"这不是对你所提问题的回答"**（2026-10-06）。
     * 起因：有人没配 --ai-endpoint 就打 /ai/ask，两个不同问题拿到逐字节相同的权限摘要，
     * 于是判断"有 bug"。信封里的 source=fallback 标了，但**只读文本的人不会去看信封**。
     */
    let fbAns = aiPermFallbackAnswer("可查看成员名录")
    t.ok("兜底答案自述『不是对你所提问题的回答』", fbAns.contains("不是对你所提问题的回答"))
    t.ok("兜底答案仍带权限事实（D2：兜底不得为空）", fbAns.contains("可查看成员名录"))
    t.ok("正常文案**不**自述降级（否则模型真答了也像假的）",
         !aiPermAnswer("可查看成员名录").contains("不是对你所提问题的回答"))

    /*
     * §7.5 风控缓存**必须能淘汰**（2026-10-06 修的真 bug）。
     *
     * 审计时发现：`aiRiskCachePut` 只写入、从不淘汰，而注释还写着"与限流器同款"
     * —— 限流器有 AI_RATE_PRUNE_AT 会清理，这个没有。于是**每个被评过一次的申请人
     * 都会永久留一条**（哪怕早已通过审批、不再出现在列表里），属无界增长。
     */
    let mKeep = mkMember(901, "member", 2)
    let mDrop = mkMember(902, "member", 2)
    let fEvict = RiskFacts()
    /* 走 pendingRiskOf（ai=None）会落缓存 —— 正好用来铺两条 */
    pendingRiskOf(mKeep, fEvict, None, false)
    pendingRiskOf(mDrop, fEvict, None, false)
    t.ok("风控缓存：两条都进去了", aiRiskCached(901) && aiRiskCached(902))

    let keepIds = HashSet<Int64>()
    keepIds.add(901)
    aiRiskCacheRetain(keepIds)
    t.ok("风控缓存：**在列表里的保留**", aiRiskCached(901))
    t.ok("★ 风控缓存：**不在列表里的被淘汰**（修无界增长）", !aiRiskCached(902))

    aiRiskCacheRetain(HashSet<Int64>())
    t.ok("风控缓存：列表为空时全部清掉", !aiRiskCached(901))
}

public func runTests(mysqlCfg: ?MySqlConfig): Int64 {
    println("=== 社团管理工具 · 服务端单测 ===")
    let t = TR()
    testTime(t)
    testStr(t)
    testIds(t)
    testPassword(t)
    testLimits(t)
    testRequestJsonTypes(t)
    testTaskPatchWhitelist(t)
    testStore(t)
    testDeferredSave(t)
    testTokenPrune(t)
    testSortEdge(t)
    testLoopbackPeer(t)
    testLoginCreds(t)
    testAuditDeferred(t)
    testPbkdf2Gate(t)
    testPerms(t)
    testAi(t)
    testRegThrottle(t)
    testRbacAdaptation(t)
    testViews(t)
    testPart3Views(t)
    testPaging(t)
    testTasks(t)
    testPlans(t)
    match (mysqlCfg) {
        case Some(cfg) => testMysqlRoundTrip(t, cfg)
        case None =>
            println("- MySQL 持久化往返：**已跳过**（未给 DSN）")
            println("  （给一个 DSN 就会跑：club-server test mysql://user:pass@host:port/db）")
    }
    println("")
    println("PASS ${t.pass} / FAIL ${t.fail}")
    if (t.fail == 0) {
        return 0
    }
    return 1
}

/*
 * ===================== MySQL 持久化往返（2026-09-20） =====================
 *
 * 为什么必须有这一条：路线 B 把持久化整个换掉了，而原来那批 `testStore` 测的是
 * **文件后端**（Store.mysql == None）。如果只留文件那批，"MySQL 这条链子到底能不能
 * 把数据原样搬过去搬回来"就完全没有断言 —— 一旦哪天 store.cj 加了字段、mysql_store.cj
 * 的列清单忘了跟，测试会全绿而线上丢字段。
 *
 * 测法刻意用**空库 + 一个 Store 往返**，并且直接复用 deptToJson 那套：
 *   ① 建表（幂等，跑第二次也不报错）
 *   ② 把一个填满 7 张表 + 元数据的内存 Store 写进库（storeSaveNow → writeDbToMysql）
 *   ③ 从库读回另一个 Store（storeLoadDb）
 *   ④ 逐字段比对（不是"能读回来就行"，而是比对**每一个字段**）
 *   ⑤ 再写一次，证明"整体替换"不会累积（第二次应仍是同样的行数，不是翻倍）
 *
 * 用完**清掉自己写的行**（DELETE FROM 各表），不给下一次运行留脏数据。
 */
func testMysqlRoundTrip(t: TR, cfg: MySqlConfig): Unit {
    println("- MySQL 持久化往返（真实的库，会写也会清）")
    var ms: ?MysqlStore = None
    try {
        ensureDatabase(cfg)
        ms = Some(MysqlStore(cfg))
    } catch (e: Exception) {
        /* 连不上就是**失败**，不是跳过 —— 调用方既然给了 DSN，就该能连上 */
        t.ok("MySQL 可连（${cfg.describe()}）：${e.message}", false)
        return
    }
    let db = match (ms) {
        case Some(x) => x
        case None => return
    }
    t.ok("MySQL 可连（${cfg.describe()}）", true)
    ensureSchema(db)
    ensureSchema(db) /* 幂等：第二次不报错 */

    /* 先清干净，保证断言是"这一次写进去的东西" */
    for (tb in ["departments", "members", "plans", "tasks", "invite_links",
                "tokens", "idem", "meta", "meta_str"]) {
        db.x("DELETE FROM " + tb, Array<DbValue>())
    }

    let s = Store("build/test-data-mysql")
    s.mysql = Some(db)

    let d = Department()
    d.id = 1
    d.name = "课题部"
    d.sort = 7
    s.departments[1] = d

    let m = Member()
    m.id = 3
    m.name = "张三"
    m.phone = "13800000000"
    m.pw_algo = "pbkdf2-sha256"
    m.pw_iter = 100000
    m.pw_salt = "aa"
    m.pw_hash = "bb"
    m.role = "lead"
    m.dept_id = 1
    m.dept_hint = 2
    m.status = "active"
    m.joined_at = 1789898400
    s.members[3] = m
    s.next_member = 4

    let p = Plan()
    p.id = 2
    /*
     * ⚠ 标题里的 emoji 是**回归闸门**（2026-10-04 修的 P0）：它是 4 字节 UTF-8。
     * 驱动握手把连接字符集写死成 utf8mb3（id 33），而库/表是 utf8mb4 ——
     * 不显式发 `SET NAMES utf8mb4`（见 MysqlStore 的构造）时，这一行就会让落盘报
     * error 1366 Incorrect string value，**并把之后所有写入一起卡死**。
     * 所以这条断言不只是"标题往返"，它钉的是"4 字节字符能不能落库"。
     */
    p.title = "2026 招新🙂"
    p.desc = "含 ' 单引号 与 \\ 反斜杠"   /* 引号/反斜杠：参数化绑定的边界用例 */
    p.parent_id = 0
    p.owner_id = 3
    p.dept_id = 1
    p.due_at = 1789898400
    p.created_by = 3
    p.created_at = 1789898400
    p.updated_at = 1789898400
    s.plans[2] = p
    s.next_plan = 3

    let x = Task()
    x.id = 5
    /*
     * ⚠ 标题里**故意带一个 4 字节 UTF-8 字符**（emoji U+1F642）—— 这是 P0 的回归闸门。
     *   驱动握手把连接字符集写死成 utf8mb3(id 33)，不补 `SET NAMES utf8mb4` 时，
     *   这一行的 INSERT 会报 `1366 Incorrect string value`（见 mysql_store.cj 构造里的长注释）。
     *   字节数：`2026 ` = 5，`招新` = 6，emoji = 4，合计 **15**。
     */
    x.title = "2026 招新🙂"
    /*
     * ⚠ 这条 desc 是**参数绑定的边界用例**，两个字符都要原样回来：
     *   · 单引号 `'`：框架的 sqlEscape 会双写成 `''`；
     *   · 反斜杠 `\`：MySQL 默认还开着一层反斜杠转义 —— 不处理就会把 `\` 吃掉
     *     （本机 MariaDB 11.4 的 sql_mode 里**没有** NO_BACKSLASH_ESCAPES）。
     * 见 mysql_store.cj 的 mysqlSafe() 与 db.cj 的 sqlEscape 注释。
     */
    x.desc = "需确认容纳人数 含 ' 与 \\ 反斜杠"
    x.owner_id = 3
    x.plan_id = 2
    x.dept_id = 1
    x.status = "blocked"
    x.blocker = "场地没批"
    x.help_dept_id = 1
    x.help_member_id = 3
    x.due_at = 1789898400
    x.updated_at = 1789898400
    x.completed_at = 0
    x.deleted_at = 0
    x.source = "app"
    x.created_by = 3
    x.created_at = 1789898400
    s.tasks[5] = x
    s.next_task = 6

    let l = DeptInviteLink()
    l.token = "tok-abc"
    l.dept_id = 1
    l.enabled = false
    l.created_by = 3
    l.created_at = 1789898400
    s.invite_links["tok-abc"] = l

    let tok = TokenRecord()
    tok.member_id = 3
    tok.created_at = 1789898400
    tok.expires_at = 1789898500
    s.tokens["tk-1"] = tok

    let idr = IdemRecord()
    idr.resource_id = 5
    idr.created_at = 1789898400
    s.idem["task:3:ct-1"] = idr

    s.register_code = "K3M9P2"
    s.register_code_by = 3
    s.register_code_at = 1789898400
    s.next_dept = 2

    /* ② 写进库（走的就是请求链上那条路：storeSaveNow → writeSnapshot → writeDbToMysql） */
    storeSaveNow(s)

    /* ③ 读回一个全新的 Store */
    let back = storeLoadDb(db, "build/test-data-mysql")
    /* 加载后必须已经设好"已落盘基准" —— 否则从内存删行时那条 DELETE 会没人负责
     * （见 storeLoadDb 末尾的注释）。这条断言就是那个缺口的闸门。 */
    t.ok("MySQL：加载后已建立增量落盘基准", back.persisted.isSome())

    /* ④ 逐字段比对 */
    t.eqi("MySQL：部门数", back.departments.size, 1)
    match (back.departments.get(1)) {
        case Some(bd) =>
            t.eqs("MySQL：部门名往返", bd.name, "课题部")
            t.eqi("MySQL：部门 sort 往返", bd.sort, 7)
        case None => t.ok("MySQL：部门 1 存在", false)
    }
    t.eqi("MySQL：成员数", back.members.size, 1)
    match (back.members.get(3)) {
        case Some(bm) =>
            t.eqs("MySQL：姓名（中文）往返", bm.name, "张三")
            t.eqs("MySQL：手机号往返", bm.phone, "13800000000")
            t.eqs("MySQL：口令算法往返", bm.pw_algo, "pbkdf2-sha256")
            t.eqi("MySQL：口令迭代往返", bm.pw_iter, 100000)
            t.eqs("MySQL：口令盐往返", bm.pw_salt, "aa")
            t.eqs("MySQL：口令摘要往返", bm.pw_hash, "bb")
            t.eqs("MySQL：角色往返", bm.role, "lead")
            t.eqi("MySQL：部门 id 往返", bm.dept_id, 1)
            t.eqi("MySQL：部门预填往返", bm.dept_hint, 2)
            t.eqs("MySQL：状态往返", bm.status, "active")
            t.eqi("MySQL：加入时间往返", bm.joined_at, 1789898400)
        case None => t.ok("MySQL：成员 3 存在", false)
    }
    match (back.plans.get(2)) {
        case Some(bp) =>
            /* ★ P0 回归闸门：标题里的 emoji 是 4 字节 UTF-8。
             * 少了 MysqlStore 构造里的 `SET NAMES utf8mb4`，这里会红（落盘就抛 1366）。 */
            t.eqs("MySQL：课题标题含 4 字节字符（emoji）往返", bp.title, "2026 招新🙂")
            /* 按**字节**计（Cangjie 的 String.size 就是字节数）：
             * "2026"=4 + " "=1 + "招"=3 + "新"=3 + "🙂"=4 = 15 */
            t.eqi("MySQL：4 字节字符未被截断（字节数）", bp.title.size, 4 + 1 + 3 + 3 + 4)
            /* 这条是**参数化绑定**的边界用例：单引号 + 反斜杠都要原样回来 */
            t.eqs("MySQL：课题描述（引号/反斜杠）往返", bp.desc, "含 ' 单引号 与 \\ 反斜杠")
            t.eqi("MySQL：课题负责人往返", bp.owner_id, 3)
            t.eqi("MySQL：课题截止往返", bp.due_at, 1789898400)
        case None => t.ok("MySQL：课题 2 存在", false)
    }
    match (back.tasks.get(5)) {
        case Some(bt) =>
            t.eqs("MySQL：任务标题（含 4 字节字符）往返", bt.title, "2026 招新🙂")
            /* P0 闸门：把 mysql_store.cj 构造里的 `SET NAMES utf8mb4` 撤掉，这一条当场红 */
            t.eqi("MySQL：4 字节字符按 15 字节原样回来", bt.title.size, 15)
            t.eqs("MySQL：任务状态往返", bt.status, "blocked")
            /* 反斜杠 + 单引号一起走：见上面 x.desc 的注释 */
            t.eqs("MySQL：任务描述（引号/反斜杠）往返", bt.desc, "需确认容纳人数 含 ' 与 \\ 反斜杠")
            t.eqs("MySQL：任务阻塞原因往返", bt.blocker, "场地没批")
            t.eqi("MySQL：求助部门往返", bt.help_dept_id, 1)
            t.eqi("MySQL：求助成员往返", bt.help_member_id, 3)
            t.eqs("MySQL：任务来源往返", bt.source, "app")
        case None => t.ok("MySQL：任务 5 存在", false)
    }
    match (back.invite_links.get("tok-abc")) {
        case Some(bl) =>
            t.eqi("MySQL：招募链接部门往返", bl.dept_id, 1)
            /* false 往返：整数化的 TINYINT 列最容易在这里出岔（0 被当成"没填"） */
            t.ok("MySQL：招募链接 enabled=false 往返", bl.enabled == false)
        case None => t.ok("MySQL：招募链接存在", false)
    }
    match (back.tokens.get("tk-1")) {
        case Some(btk) => t.eqi("MySQL：令牌成员往返", btk.member_id, 3)
        case None => t.ok("MySQL：令牌存在", false)
    }
    match (back.idem.get("task:3:ct-1")) {
        case Some(bi) => t.eqi("MySQL：幂等映射往返", bi.resource_id, 5)
        case None => t.ok("MySQL：幂等记录存在", false)
    }
    t.eqs("MySQL：注册口令往返", back.register_code, "K3M9P2")
    t.eqi("MySQL：注册口令改动人往返", back.register_code_by, 3)
    t.eqi("MySQL：next_member 往返", back.next_member, 4)
    t.eqi("MySQL：next_dept 往返", back.next_dept, 2)

    /* ⑤ 再写一次：**增量落盘**不能把重复行累积起来 */
    storeSaveNow(back)
    let rows = db.q("SELECT COUNT(*) FROM members", Array<DbValue>())
    t.eqs("MySQL：二次落盘不累积", rows.cell(0, 0), "1")

    /*
     * ⑥ 增量落盘的**删除**面：删掉内存里的记录后必须从库里消失。
     *
     * 这一段是"改成增量写入"之后最需要盯的地方：原先每次都是 `DELETE FROM 全表 + 重插`，
     * 删除是"顺带"完成的；现在只写变化，删除必须**显式**发 `DELETE WHERE pk=?` ——
     * 漏了它就会出现"内存里删了、库里还在"，重启后数据复活（最坏的一类不一致）。
     */
    back.members.remove(3)
    back.tasks.remove(5)
    back.plans.remove(2)
    back.invite_links.remove("tok-abc")
    back.tokens.remove("tk-1")
    back.idem.remove("task:3:ct-1")
    back.departments.remove(1)
    storeSaveNow(back)

    let after = storeLoadDb(db, "build/test-data-mysql")
    t.eqi("MySQL：删成员后库里也没了", after.members.size, 0)
    t.eqi("MySQL：删任务后库里也没了", after.tasks.size, 0)
    t.eqi("MySQL：删课题后库里也没了", after.plans.size, 0)
    t.eqi("MySQL：删部门后库里也没了", after.departments.size, 0)
    t.eqi("MySQL：删招募链接后库里也没了", after.invite_links.size, 0)
    t.eqi("MySQL：删令牌后库里也没了", after.tokens.size, 0)
    t.eqi("MySQL：删幂等记录后库里也没了", after.idem.size, 0)

    /*
     * ⑦ 增量落盘的**"没变就不写"**面：连着两次 storeSaveNow（第二次无任何变化）
     *    不应报错，也不影响数据。这条挡的是"基准没更新 → 每次都当全量重写"的退步，
     *    以及"REPLACE 语义写错导致重复行"的情形。
     */
    storeSaveNow(back)
    storeSaveNow(back)
    let rows2 = db.q("SELECT COUNT(*) FROM members", Array<DbValue>())
    t.eqs("MySQL：无变化的重复落盘仍为 0 行", rows2.cell(0, 0), "0")

    /*
     * ⑧ **重启后删除仍然生效**（生产路径的闸门）。
     *
     * 上面 ⑥ 是"在同一个进程里删了再写"。真实场景是：重启 → 加载 → 删 → 落盘 → 再重启。
     * 这一段的要点是**不要**手工清 `persisted`：它必须由 storeLoadDb 设好，
     * 否则"删掉的那一行"在库里没人负责删（这正是加载时设基准要挡的缺口）。
     * 把 persisted 清掉，这条就会红。
     */
    storeSaveNow(back)
    let re = storeLoadDb(db, "build/test-data-mysql")
    t.ok("MySQL：重新加载后仍有基准", re.persisted.isSome())
    re.tasks.remove(5)          /* 库里现在只有这一个任务（⑦ 之后成员已空） */
    t.ok("MySQL：加载后确有 1 个任务可删", re.tasks.size == 0)
    storeSaveNow(re)
    let re2 = storeLoadDb(db, "build/test-data-mysql")
    t.eqi("MySQL：重启后删掉的任务真的不在了", re2.tasks.size, 0)

    /*
     * ⑨ **计数器落后于实际最大 id 时，加载必须把它抬上去**（2026-09-20 补）。
     *
     * 为什么必须有这条：`next_dept` 之类是"下一个要分配的 id"。它若比库里已有的最大 id 小，
     * 新建记录算出来的 id 就会**命中一条已有行**，而落盘是 `REPLACE INTO` ——
     * 一条无关的成员/任务被**静默覆盖**（本项目最不能接受的一类失败）。而"计数器落后"
     * 不需要有人手工改库：任何绕过 club-server 的批量插行都会留下它 ——
     * `tests\bench.ps1` 造数就必须手工补 `UPDATE meta ... next_member`，
     * 它的注释写着"否则新注册会和克隆出来的 id 撞车"。
     *
     * 做法：造一条 id=41 的部门并落盘（此时 meta 里 next_dept=42），
     * 再把 meta 里的 next_dept **手工改成 1**（模拟"别人插了行没改计数器"），
     * 然后重新加载 —— 期望 next_dept 被抬到 42（最大 id + 1），而不是 1。
     * 去掉 idFloor 这条就红（会拿到 1，下一次新建部门就会 REPLACE 掉 id=41 那条）。
     */
    let probeDept = Department()
    probeDept.id = 41
    probeDept.name = "计数探针"
    let probeStore = Store("build/test-data-mysql")
    probeStore.mysql = Some(db)
    probeStore.departments[41] = probeDept
    probeStore.next_dept = 42
    storeSaveNow(probeStore)
    db.x("UPDATE meta SET v = 1 WHERE `k` = 'next_dept'", Array<DbValue>())

    let floored = storeLoadDb(db, "build/test-data-mysql")
    t.eqi("MySQL：meta 里的 next_dept 落后时，加载抬到最大 id + 1", floored.next_dept, 42)
    t.eqi("MySQL：抬计数器不影响已载入的数据", floored.departments.size, 1)
    t.ok("MySQL：id=41 那条部门没被当成下一个 id 覆盖掉", floored.departments.contains(41))

    /* 清理：不给下一次运行留脏数据 */
    for (tb in ["departments", "members", "plans", "tasks", "invite_links",
                "tokens", "idem", "meta", "meta_str"]) {
        db.x("DELETE FROM " + tb, Array<DbValue>())
    }
}
