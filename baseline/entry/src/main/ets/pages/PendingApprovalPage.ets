// 负责人：杨睿（前端组长）
// 待分配审批页 —— 待分配成员列表 / 多选 + 全选批量分配部门角色 / 结果汇总（中文错误码映射）
// 交互：成员多选 -> 当前页选择部门/角色 -> assign-batch 提交 -> 汇总结果
// 真实接口：MemberApi.pending() / MemberApi.assignBatch() / DeptApi.list()

import type { DeptBrief } from '../api/AuthApi';
import { MemberApi, PendingMemberView, AssignBatchResponse, BatchFailItem } from '../api/MemberApi';
import { DeptApi, DeptView } from '../api/DeptApi';
import { Color, StatusColor, Space, Radius, FontSize, Shadow } from '../core/Theme';
import { backPage } from '../utils/RouterUtils';

interface PendingMemberUI {
  id: number;
  name: string;
  deptHint: DeptBrief | null;
  registeredAt: string;
  riskLevel: string;     // '' = 无风险（服务端尚未下发 risk，防御式留空）
  riskReasons: string[];
}

interface Dept {
  id: number;
  name: string;
}

interface RoleOption {
  key: string;
  label: string;
}

const ROLE_OPTIONS: RoleOption[] = [
  { key: 'member', label: '成员' },
  { key: 'vice_lead', label: '副部长' },
  { key: 'lead', label: '部长' },
  { key: 'vice_president', label: '副会长' },
];

function batchFailMsg(code: string): string {
  if (code === 'FORBIDDEN_ROLE') return '不能作用于同权或更高权的人';
  if (code === 'FORBIDDEN_LAST_PRESIDENT') return '系统必须始终保留至少一位会长';
  if (code === 'FORBIDDEN_NOT_IN_DEPT') return '不能操作其他部门';
  if (code === 'MEMBER_NOT_FOUND') return '成员不存在';
  if (code === 'MEMBER_DISABLED') return '该成员已退出社团';
  if (code === 'INVALID_ROLE') return '角色无效';
  if (code === 'DEPT_NOT_FOUND') return '部门不存在';
  return '分配失败';
}

function registrationLabel(value: string): string {
  if (value.length === 0) return '注册时间未知';
  const date = new Date(value);
  const time = date.getTime();
  if (Number.isNaN(time)) return value;

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const dateStart = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  const days = Math.floor((todayStart - dateStart) / 86400000);
  if (days <= 0) return '今天注册';
  if (days === 1) return '昨天注册';
  return `${days} 天前注册`;
}

function deptHintLabel(member: PendingMemberUI): string {
  if (member.deptHint === null) return '未指定部门';
  return member.deptHint.name;
}

function riskLevelLabel(level: string): string {
  if (level === 'high') return '高风险';
  if (level === 'medium') return '中风险';
  return '低风险';
}

function riskLevelFg(level: string): string {
  if (level === 'high') return '#DC2626';
  if (level === 'medium') return '#B45309';
  return '#16A34A';
}

function riskLevelBg(level: string): string {
  if (level === 'high') return '#FEE2E2';
  if (level === 'medium') return '#FEF3C7';
  return '#DCFCE7';
}

@Component
export default struct PendingApprovalPage {
  @State members: PendingMemberUI[] = [];
  @State depts: Dept[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State selectedDeptIndex: number = 0;
  @State selectedRoleIndex: number = 0;
  @State selectedMemberIds: number[] = [];
  @State assigning: boolean = false;
  @State lastResultSummary: string = '';
  @State lastResultDetail: string = '';
  private memberApi: MemberApi = new MemberApi();
  private deptApi: DeptApi = new DeptApi();

  aboutToAppear(): void {
    this.loadData();
  }

  async loadData(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    this.lastResultSummary = '';
    this.lastResultDetail = '';
    await this.loadDepts();
    await this.loadPending();
    this.loading = false;
  }

  async loadDepts(): Promise<void> {
    const resp = await this.deptApi.list();
    if (resp.ok && resp.data) {
      this.depts = resp.data.items.map((d: DeptView): Dept => ({ id: d.id, name: d.name }));
      this.selectedDeptIndex = 0;
    } else {
      this.errorMsg = resp.error?.message ?? '加载部门失败';
    }
  }

  async loadPending(): Promise<void> {
    const resp = await this.memberApi.pending();
    if (resp.ok && resp.data) {
      this.members = resp.data.items.map((v: PendingMemberView): PendingMemberUI => ({
        id: v.id,
        name: v.name,
        deptHint: v.dept_hint,
        registeredAt: v.registered_at ?? '',
        riskLevel: v.risk?.level ?? '',
        riskReasons: v.risk?.reasons ?? [],
      }));
      this.selectedMemberIds = [];
    } else {
      this.errorMsg = resp.error?.message ?? '加载待审批成员失败';
    }
  }

  selectedCount(): number {
    return this.selectedMemberIds.length;
  }

  isMemberSelected(id: number): boolean {
    return this.selectedMemberIds.indexOf(id) >= 0;
  }

  toggleMember(id: number): void {
    if (this.isMemberSelected(id)) {
      this.selectedMemberIds = this.selectedMemberIds.filter((selectedId: number): boolean => selectedId !== id);
    } else {
      this.selectedMemberIds = [...this.selectedMemberIds, id];
    }
  }

  clearSelection(): void {
    this.selectedMemberIds = [];
  }

  buildResultSummary(data: AssignBatchResponse, deptName: string, roleLabel: string): void {
    const successCount = data.succeeded.length;
    const failCount = data.failed.length;
    const codes: string[] = [];
    for (let i = 0; i < data.failed.length; i++) {
      const code = data.failed[i].code;
      if (codes.indexOf(code) < 0) {
        codes.push(code);
      }
    }

    this.lastResultSummary = `上次结果 · 成功 ${successCount} 条，失败 ${failCount} 条`;
    if (failCount > 0) {
      const codeText = codes.length > 0 ? codes.join('、') : 'UNKNOWN';
      this.lastResultDetail = `${codeText}：${batchFailMsg(codes.length > 0 ? codes[0] : '')}；失败条目保留选中以便重试。`;
    } else {
      this.lastResultDetail = `${deptName} · ${roleLabel} 已分配，成功成员已从列表移除。`;
    }
  }

  async submitAssign(): Promise<void> {
    if (this.assigning || this.depts.length === 0) return;
    const selected = this.members.filter((m: PendingMemberUI): boolean => this.isMemberSelected(m.id));
    if (selected.length === 0) return;

    this.assigning = true;
    const dept = this.depts[this.selectedDeptIndex];
    const role = ROLE_OPTIONS[this.selectedRoleIndex];
    const memberIds = selected.map((m: PendingMemberUI): number => m.id);
    const resp = await this.memberApi.assignBatch({
      dept_id: dept.id,
      role: role.key,
      member_ids: memberIds,
    });

    if (resp.ok && resp.data) {
      const data = resp.data;
      const succeededIds = data.succeeded;
      this.buildResultSummary(data, dept.name, role.label);
      this.members = this.members.filter((m: PendingMemberUI): boolean => !succeededIds.includes(m.id));
      this.selectedMemberIds = this.selectedMemberIds.filter((id: number): boolean => !succeededIds.includes(id));
    } else {
      this.lastResultSummary = '上次结果 · 提交失败';
      this.lastResultDetail = `${resp.error?.message ?? '分配失败'}；已选成员保持不变，可重试。`;
    }
    this.assigning = false;
  }

  @Builder
  headerBuilder() {
    Row() {
      Row({ space: 4 }) {
        Image($r('app.media.icon_chevron_left_primary'))
          .width(18)
          .height(18)

        Text('待分配审批')
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor('#155DFC')
      }
      .height('100%')
      .onClick(() => backPage())

      Blank()

      Text(`${this.members.length} 人待处理`)
        .fontSize(FontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor('#155DFC')
    }
    .width('100%')
    .height(52)
    .padding({ left: Space.page, right: Space.page })
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#FFFFFF')
  }

  @Builder
  memberRowBuilder(member: PendingMemberUI, showDivider: boolean) {
    if (showDivider) {
      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')
    }

    Row({ space: 12 }) {
      Stack() {
        if (this.isMemberSelected(member.id)) {
          Text('✓')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
      }
      .width(20)
      .height(20)
      .backgroundColor(this.isMemberSelected(member.id) ? '#155DFC' : '#FFFFFF')
      .border({ width: 2, color: this.isMemberSelected(member.id) ? '#155DFC' : '#D1D5DB' })
      .borderRadius(4)

      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(member.name)
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor('#101828')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (member.riskLevel.length > 0) {
            this.riskBadge(member.riskLevel)
          }
        }
        .width('100%')

        Text(`${registrationLabel(member.registeredAt)} · dept_hint：${deptHintLabel(member)}`)
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#99A1AF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (member.riskReasons.length > 0) {
          Text(member.riskReasons.join('；'))
            .width('100%')
            .fontSize(FontSize.micro)
            .fontColor('#99A1AF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => this.toggleMember(member.id))
  }

  @Builder
  riskBadge(level: string) {
    Text(riskLevelLabel(level))
      .fontSize(FontSize.micro)
      .fontWeight(FontWeight.Medium)
      .fontColor(riskLevelFg(level))
      .backgroundColor(riskLevelBg(level))
      .borderRadius(Radius.pill)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
  }

  @Builder
  memberListBuilder() {
    Column() {
      ForEach(this.members, (member: PendingMemberUI, index: number) => {
        this.memberRowBuilder(member, index > 0)
      }, (member: PendingMemberUI): string => `${member.id}-${this.isMemberSelected(member.id) ? '1' : '0'}`)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
  }

  @Builder
  assignCardBuilder() {
    Column({ space: 14 }) {
      Row() {
        Text(`已选 ${this.selectedCount()} 人`)
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')

        Blank()

        Text('取消选择')
          .fontSize(FontSize.caption)
          .fontColor('#155DFC')
          .onClick(() => this.clearSelection())
      }
      .width('100%')

      Row() {
        Text('分配部门')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')

        Blank()

        Select(this.depts.map((d: Dept): SelectOption => ({ value: d.name })))
          .selected(this.selectedDeptIndex)
          .value(this.depts.length > 0 ? this.depts[this.selectedDeptIndex].name : '暂无部门')
          .fontColor('#2563EB')
          .backgroundColor('#00000000')
          .borderRadius(0)
          .onSelect((index: number) => {
            this.selectedDeptIndex = index;
          })
          .width(132)
      }
      .width('100%')

      Row() {
        Text('角色')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')

        Blank()

        Select(ROLE_OPTIONS.map((r: RoleOption): SelectOption => ({ value: r.label })))
          .selected(this.selectedRoleIndex)
          .value(ROLE_OPTIONS[this.selectedRoleIndex].label)
          .fontColor('#00A63E')
          .backgroundColor('#00000000')
          .borderRadius(0)
          .onSelect((index: number) => {
            this.selectedRoleIndex = index;
          })
          .width(132)
      }
      .width('100%')

      Button(this.assigning ? '提交中…' : '一次提交（assign-batch）')
        .width('100%')
        .height(44)
        .type(ButtonType.Normal)
        .fontSize(FontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#155DFC')
        .borderRadius(12)
        .enabled(!this.assigning && this.depts.length > 0)
        .onClick(() => this.submitAssign())
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E5E7EB' })
    .borderRadius(12)
    .shadow(Shadow.L2)
  }

  @Builder
  resultBuilder() {
    Column({ space: 4 }) {
      Text(this.lastResultSummary)
        .width('100%')
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor('#6A7282')

      Text(this.lastResultDetail)
        .width('100%')
        .fontSize(FontSize.micro)
        .fontColor('#99A1AF')
        .lineHeight(17)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor('#F3F4F6')
    .borderRadius(12)
  }

  @Builder
  loadingBuilder() {
    Column() {
      LoadingProgress()
        .width(32)
        .height(32)
        .color('#155DFC')

      Text('正在加载待分配成员…')
        .fontSize(FontSize.caption)
        .fontColor('#99A1AF')
        .margin({ top: Space.md })
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorBuilder() {
    Column() {
      Text(this.errorMsg)
        .width('100%')
        .fontSize(FontSize.body)
        .fontColor('#FB2C36')
        .textAlign(TextAlign.Center)

      Button('重试')
        .type(ButtonType.Capsule)
        .backgroundColor('#155DFC')
        .fontColor('#FFFFFF')
        .margin({ top: Space.md })
        .onClick(() => this.loadData())
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyBuilder() {
    Column() {
      Image($r('app.media.clock_pending'))
        .width(68)
        .height(68)
        .margin({ bottom: Space.lg })

      Text('暂无待审批成员')
        .fontSize(FontSize.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor('#101828')
        .margin({ bottom: Space.xs })

      Text('新成员注册后会出现在这里')
        .fontSize(FontSize.caption)
        .fontColor('#99A1AF')
    }
    .width('100%')
    .height(280)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      this.headerBuilder()

      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')

      Scroll() {
        Column({ space: 12 }) {
          if (this.loading) {
            this.loadingBuilder()
          } else if (this.errorMsg.length > 0) {
            this.errorBuilder()
          } else {
            if (this.members.length === 0) {
              this.emptyBuilder()
            } else {
              Row()
                .width('100%')
                .height(112)
              this.memberListBuilder()
            }

            if (this.selectedCount() > 0) {
              this.assignCardBuilder()
            }

            if (this.lastResultSummary.length > 0) {
              this.resultBuilder()
            }
          }
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: 12, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F9FAFB')
  }
}