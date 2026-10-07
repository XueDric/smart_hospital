import { describe, it, expect } from '@ohos/hypium';
import { flattenPlans } from '../main/ets/util/PlanTree';
import type { PlanNode } from '../main/ets/api/PlanApi';

function plan(id: number, title: string, children: PlanNode[]): PlanNode {
  return {
    id: id,
    title: title,
    owner: null,
    dept: null,
    due_at: null,
    progress: { done: 0, total: 0 },
    task_count: 0,
    child_count: children.length,
    created_at: '',
    updated_at: '',
    children: children
  };
}

export default function planTreeTest() {
  describe('PlanTree', () => {
    it('flattenPlans_returnsEmptyForEmptyTree', 0, () => {
      expect(flattenPlans([]).length).assertEqual(0);
    });

    it('flattenPlans_usesParentPathAndPreorder', 0, () => {
      const leaf: PlanNode = plan(3, 'C', []);
      const child: PlanNode = plan(2, 'B', [leaf]);
      const root: PlanNode = plan(1, 'A', [child]);

      const flattened = flattenPlans([root]);

      expect(flattened.length).assertEqual(3);
      expect(flattened[0].id).assertEqual(1);
      expect(flattened[0].title).assertEqual('A');
      expect(flattened[1].id).assertEqual(2);
      expect(flattened[1].title).assertEqual('A / B');
      expect(flattened[2].id).assertEqual(3);
      expect(flattened[2].title).assertEqual('A / B / C');
    });

    it('flattenPlans_visitsSiblingsBeforeTheirChildren', 0, () => {
      const firstLeaf: PlanNode = plan(4, 'A1', []);
      const first: PlanNode = plan(2, 'A', [firstLeaf]);
      const second: PlanNode = plan(3, 'B', []);

      const flattened = flattenPlans([first, second]);

      expect(flattened.length).assertEqual(3);
      expect(flattened[0].title).assertEqual('A');
      expect(flattened[1].title).assertEqual('A / A1');
      expect(flattened[2].title).assertEqual('B');
    });
  });
}
