/**
 * 作者：刘运泽
 * 功能：幂等 client_token 生成（手写 UUID v4）
 * 修改记录：
 *   2026-09-16  首次编写
 */
// client_token 幂等（docs/api-design.md §4.5 / FRONTEND_DIVISION.md 坑表）：
// 创建任务/课题时传 UUID，24h 内重复提交返回首次结果，防手抖点两次建出两个。

export function genClientToken(): string {
  const hex = '0123456789abcdef'
  let s = ''
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      s += '-'
    } else if (i === 14) {
      s += '4'                                        // version 4
    } else if (i === 19) {
      s += hex.charAt(8 + Math.floor(Math.random() * 4))  // variant 8/9/a/b
    } else {
      s += hex.charAt(Math.floor(Math.random() * 16))
    }
  }
  return s
}
