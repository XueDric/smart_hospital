package qingzhou

import stdx.net.http.*

/*
 * SPDX-License-Identifier: MIT
 *
 * WebSocket 支持。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 封装 stdx 的 WebSocket 服务端能力（HTTP Upgrade -> 双向长连接）：
 *   - upgradeWebSocket(ctx)  在 handler 内把 HTTP 连接升级为 WebSocket
 *   - wsHandler(handler)     便捷中间件：升级 + 读循环 + 关闭，回调处理每帧
 *
 * 底层（stdx.net.http.WebSocket）：
 *   - upgradeFromServer(ctx) 服务端升级
 *   - read()/write() 读写帧（阻塞、非线程安全，单连接单线程读写）
 *   - 帧类型 TextWebFrame / BinaryWebFrame / CloseWebFrame / PingWebFrame /
 *     PongWebFrame / ContinuationWebFrame
 *
 * 用法（配合 Router 限定路径）：
 *   let router = Router()
 *   router.get("/ws", wsHandler({ ws: WebSocket, frame: WebSocketFrame =>
 *       if (frame.frameType == WebSocketFrameType.TextWebFrame) {
 *           ws.write(WebSocketFrameType.TextWebFrame, frame.payload) // echo
 *       }
 *   }))
 */

/*
 * 把当前 HTTP 连接升级为 WebSocket。成功返回 WebSocket；
 * 无 http ctx 或升级失败返回 None。
 */
public func upgradeWebSocket(ctx: Context): ?WebSocket {
    match (ctx.http) {
        case Some(h) =>
            try {
                return Some(WebSocket.upgradeFromServer(h))
            } catch (e: Exception) {
                return None
            }
        case None => return None
    }
}

/*
 * 便捷 WebSocket 中间件：升级连接后进入读循环，每收到一个非 Close 帧
 * 调用一次 handler(ws, frame)；收到 Close 帧或连接断开时关闭连接。
 * 是终端中间件（不调用 next）。
 */
public func wsHandler(handler: (WebSocket, WebSocketFrame) -> Unit): Middleware {
    return { ctx: Context, _: () -> Unit =>
        match (upgradeWebSocket(ctx)) {
            case Some(ws) =>
                try {
                    while (true) {
                        let frame = ws.read()
                        if (frame.frameType == WebSocketFrameType.CloseWebFrame) {
                            break
                        }
                        handler(ws, frame)
                    }
                    ws.closeConn()
                } catch (e: Exception) {
                    // 对端关闭 / 读异常：底层连接已断，无需再 closeConn
                }
            case None =>
                ctx.status(400)
                ctx.header("content-type", "application/json")
                ctx.body("{\"code\":400,\"message\":\"websocket upgrade failed\",\"data\":null}")
        }
    }
}
