package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 错误码表 —— 唯一权威是 api-design.md §1.3。改这里之前先改文档。
 *
 * 分工（api-design §1.2）：
 *   HTTP 状态码给网络层用（401 统一踢回登录页，不用解析 body）
 *   error.code 给业务层用（客户端 switch 出文案）
 */

import stdx.encoding.json.*

/* 业务错误。带 HTTP 状态码与可选的逐字段原因。 */
public class ApiError <: Exception {
    public let code: String
    public let status_: Int64
    public let fields: ?JsonObject

    public init(code: String, status_: Int64, msg: String, fields: ?JsonObject) {
        super(msg)
        this.code = code
        this.status_ = status_
        this.fields = fields
    }
}

/* (HTTP 状态码, 默认中文文案)。未列出的码一律 500，绝不向客户端暴露内部细节。 */
public func errorSpec(code: String): (Int64, String) {
    if (code == "VALIDATION_FAILED") {
        return (400, "参数校验失败")
    }
    if (code == "REGISTER_CODE_INVALID") {
        return (400, "社团注册口令错误")
    }
    if (code == "BLOCKER_REQUIRED") {
        return (400, "进入阻塞状态必须填写阻塞原因")
    }
    if (code == "PLAN_DEPTH_EXCEEDED") {
        return (400, "课题层级超过上限（6 层）")
    }
    if (code == "AUTH_REQUIRED") {
        return (401, "未登录或缺少令牌")
    }
    if (code == "AUTH_TOKEN_EXPIRED") {
        return (401, "登录已过期，请重新登录")
    }
    if (code == "AUTH_BAD_CREDENTIALS") {
        return (401, "手机号或密码错误")
    }
    if (code == "MEMBER_PENDING") {
        return (403, "账号尚未被分配部门与角色")
    }
    if (code == "MEMBER_DISABLED") {
        return (403, "该成员已退出社团")
    }
    if (code == "FORBIDDEN_ROLE") {
        return (403, "当前角色无权执行此操作")
    }
    if (code == "FORBIDDEN_NOT_IN_DEPT") {
        return (403, "不能操作其他部门的资源")
    }
    if (code == "MEMBER_NOT_FOUND") {
        return (404, "成员不存在")
    }
    if (code == "DEPT_NOT_FOUND") {
        return (404, "部门不存在")
    }
    if (code == "PLAN_NOT_FOUND") {
        return (404, "课题不存在")
    }
    if (code == "TASK_NOT_FOUND") {
        return (404, "任务不存在")
    }
    if (code == "ALREADY_EXISTS") {
        return (409, "已存在")
    }
    if (code == "DEPT_NOT_EMPTY") {
        return (409, "部门下还有成员，必须先清空")
    }
    if (code == "MEMBER_HAS_OPEN_TASKS") {
        return (409, "该成员名下还有未完成任务，需先转交")
    }
    if (code == "FORBIDDEN_LAST_PRESIDENT") {
        return (409, "系统必须始终保留至少一位会长")
    }
    if (code == "PLAN_CYCLE_DETECTED") {
        return (409, "不能把课题移动到它自己或它的子课题下")
    }
    if (code == "TOO_MANY_ATTEMPTS") {
        return (429, "尝试过于频繁，请稍后再试")
    }
    /* api-design Part 7：智能接口的成员级节流（防刷、防费用失控）。
       注意「模型不可用」**不占错误码**——它走 data.source 降级，HTTP 仍是 200。 */
    if (code == "AI_RATE_LIMITED") {
        return (429, "智能请求过于频繁，请稍后再试")
    }
    /* api-design Part 7.9：AI 写操作的确认令牌。
       注意这些**不是"降级"**：写操作失败必须显式报错（与读操作的"永不 5xx + fallback"有意分家）。 */
    if (code == "AI_PROPOSAL_NOT_FOUND") {
        return (404, "确认令牌不存在或不属于你")
    }
    if (code == "AI_PROPOSAL_USED") {
        return (409, "这个提议已经执行过了")
    }
    if (code == "AI_PROPOSAL_EXPIRED") {
        return (410, "确认已超时（5 分钟），请重新让助手提议")
    }
    if (code == "AI_PROPOSAL_EXEC_FAILED") {
        /* 执行被业务规则拒（如 blocked 缺 blocker）—— 显式报错，**不降级** */
        return (409, "执行失败")
    }
    /* 2026-09-17：bodyLimit 中间件（limits.cj）用这两个 —— 请求体在**进内存之前**就被拒。
     * 权威表是 api-design.md §1.3，两处必须同步（本节开头那句纪律）。 */
    if (code == "PAYLOAD_TOO_LARGE") {
        return (413, "请求体过大")
    }
    if (code == "UNSUPPORTED_MEDIA_TYPE") {
        return (415, "请求体格式不受支持")
    }
    /* 2026-09-18：bodyLimit 的长度判定（limits.cj）用这个 —— 请求体长度不可判定时拒绝。 */
    if (code == "LENGTH_REQUIRED") {
        return (411, "请求体长度不可判定")
    }
    /* 2026-09-18：框架 bodyParser 的 JSON 解析失败 —— 统一走我们的错误信封（见 limits.cj）。 */
    if (code == "INVALID_JSON") {
        return (400, "请求体不是合法 JSON")
    }
    return (500, "服务端错误")
}

/* 用错误码表里的默认文案抛错。 */
public func apiErr(code: String): ApiError {
    let spec = errorSpec(code)
    return ApiError(code, spec[0], spec[1], None)
}

/* 自定义文案（例如带上具体 id）。 */
public func apiErrMsg(code: String, msg: String): ApiError {
    let spec = errorSpec(code)
    return ApiError(code, spec[0], msg, None)
}

/* 带逐字段原因，供表单逐字段提示。 */
public func apiErrFields(code: String, msg: String, fields: JsonObject): ApiError {
    let spec = errorSpec(code)
    return ApiError(code, spec[0], msg, Some(fields))
}
