/**
 * 作者：刘运泽
 * 功能：课题树扁平化（flattenPlans，路径拼接供下拉用）
 * 修改记录：
 *   2026-09-16  首次编写
 */
// 把课题树拍平成 {id, title}，title 用「A / B / C」路径拼接，供选择器/筛选下拉用。

import type { PlanNode } from '../api/PlanApi'
import type { PlanRef } from '../api/TaskApi'

function walk(nodes: PlanNode[], prefix: string, out: PlanRef[]): void {
  for (const n of nodes) {
    const title = prefix.length > 0 ? `${prefix} / ${n.title}` : n.title
    out.push({ id: n.id, title })
    if (n.children.length > 0) {
      walk(n.children, title, out)
    }
  }
}

export function flattenPlans(nodes: PlanNode[]): PlanRef[] {
  const out: PlanRef[] = []
  walk(nodes, '', out)
  return out
}
