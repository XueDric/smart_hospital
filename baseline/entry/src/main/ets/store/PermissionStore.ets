// 负责人：彭翌菲
// 保存当前用户与权限并集中实现 can() 判定，
// 处理角色权重、同权保护和最后会长等前端权限规则。

import type { MemberBrief, MemberSelf, UserPermissions } from '../api/AuthApi';

export interface UpdateData {
  user: MemberSelf;
  permissions: UserPermissions;
}

export type PermissionAction =
  | 'ManageMembers'
  | 'SetRole'
  | 'EditName'
  | 'ResetPassword'
  | 'DisableMember'
  | 'CreateTask'
  | 'CreatePlan'
  | 'UpdateAnyTask'
  | 'ManageDepts'
  | 'ViewRegisterCode'
  | 'ChangeRegisterCode'
  | 'ManageInviteLinks'
  | 'TransferPresidency'
  | 'AssignPending';

/** 与服务端 roleRank 对齐；部长和副部长同档。 */
export const ROLE_WEIGHT: Record<string, number> = {
  '': 0,
  'member': 2,
  'vice_lead': 3,
  'lead': 3,
  'vice_president': 4,
  'president': 5,
};

function hasBasePermission(permissions: UserPermissions, action: PermissionAction): boolean {
  if (action === 'ManageMembers') return permissions.manage_members;
  if (action === 'SetRole') return permissions.set_role;
  if (action === 'CreateTask') return permissions.create_task;
  if (action === 'CreatePlan') return permissions.create_plan;
  if (action === 'UpdateAnyTask') return permissions.update_any_task;
  if (action === 'ManageDepts') return permissions.manage_depts === true;
  if (action === 'ViewRegisterCode') return permissions.view_register_code === true;
  if (action === 'ChangeRegisterCode') return permissions.change_register_code === true;
  if (action === 'ManageInviteLinks') return permissions.manage_invite_links === true;
  if (action === 'TransferPresidency') return permissions.transfer_presidency === true;
  if (action === 'AssignPending') return true; // 无独立布尔，由 can() 内的角色判定（会长/副会长）
  if (action === 'EditName' || action === 'ResetPassword' || action === 'DisableMember') {
    return permissions.manage_members;
  }
  return false;
}

function canActOnTarget(current: MemberSelf, target: MemberBrief): boolean {
  if (current.role === 'president') {
    return true;
  }
  const myWeight: number = ROLE_WEIGHT[current.role ?? ''] ?? 0;
  const targetWeight: number = ROLE_WEIGHT[target.role ?? ''] ?? 0;
  if (targetWeight >= myWeight) {
    return false;
  }
  if (current.role === 'vice_president') {
    return true;
  }
  if (current.role === 'lead' || current.role === 'vice_lead') {
    if (current.dept === null || target.dept === null) {
      return false;
    }
    return current.dept.id === target.dept.id;
  }
  return false;
}

/** 页面唯一的权限判定入口。服务端仍会做最终校验。 */
export function can(current: MemberSelf | null, action: PermissionAction, target?: MemberBrief): boolean {
  if (current === null || current.status !== 'active') {
    return false;
  }
  const permissions = PermissionStore.getInstance().permissions;
  if (permissions === null || !hasBasePermission(permissions, action)) {
    return false;
  }
  if (action === 'ManageMembers' || action === 'CreateTask' || action === 'CreatePlan' || action === 'UpdateAnyTask' ||
    action === 'ManageDepts' || action === 'ViewRegisterCode' || action === 'ChangeRegisterCode' ||
    action === 'ManageInviteLinks') {
    return true;
  }
  if (action === 'TransferPresidency') {
    return current.role === 'president' && target !== undefined && target.id !== current.id;
  }
  if (action === 'AssignPending') {
    return current.role === 'president' || current.role === 'vice_president';
  }
  if (target === undefined) {
    return false;
  }
  if (action === 'EditName' && current.id === target.id) {
    return current.role === 'lead' || current.role === 'vice_lead' ||
      current.role === 'vice_president' || current.role === 'president';
  }
  if (current.id === target.id) {
    return false;
  }
  return canActOnTarget(current, target);
}

export function isLastPresident(members: MemberBrief[], target: MemberBrief): boolean {
  if (target.role !== 'president') return false;
  if (target.status !== 'active') return false;
  const activePresidents: MemberBrief[] = members.filter((m: MemberBrief): boolean =>
    m.role === 'president' && m.status === 'active'
  );
  return activePresidents.length <= 1;
}

export class PermissionStore {
  private static instance: PermissionStore;

  userInfo: MemberSelf | null = null;
  permissions: UserPermissions | null = null;
  isLoggedIn: boolean = false;

  private constructor() {
  }

  static getInstance(): PermissionStore {
    if (!PermissionStore.instance) {
      PermissionStore.instance = new PermissionStore();
    }
    return PermissionStore.instance;
  }

  update(data: UpdateData): void {
    this.userInfo = data.user;
    this.permissions = data.permissions;
    this.isLoggedIn = true;
  }

  clear(): void {
    this.userInfo = null;
    this.permissions = null;
    this.isLoggedIn = false;
  }

  get isPresident(): boolean { return this.userInfo?.role === 'president'; }
  get isVicePresident(): boolean { return this.userInfo?.role === 'vice_president'; }
  get isLead(): boolean { return this.userInfo?.role === 'lead'; }
  get isViceLead(): boolean { return this.userInfo?.role === 'vice_lead'; }
  get isMember(): boolean { return this.userInfo?.role === 'member'; }
  get isPending(): boolean { return this.userInfo?.status === 'pending'; }
  get isActive(): boolean { return this.userInfo?.status === 'active'; }
}
