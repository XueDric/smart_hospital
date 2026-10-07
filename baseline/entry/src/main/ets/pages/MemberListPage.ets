/**
 * 成员名录页 MemberListPage—— 设计规格 P06
 * 郭俊杰 负责
 * 数据来源（只读，无写操作）：
 *   · GET /api/v1/depts   —— 分组顺序与每组的服务端人数（active 口径）
 *   · GET /api/v1/members —— 成员列表（⭐ 默认只返回 active；分页循环拉全）
 *   · GET /api/v1/members?status=pending&size=1 —— 只取 total，做「待分配 N 人」计数
 *
 * 交互：
 *   · 搜索框占位符「搜索姓名或部门」＝服务端 `q` 参数（姓名 OR 部门名，大小写不敏感），
 *     300ms 防抖，**不做本地过滤**（近千人规模本地过滤不成立，见 D-2 / D-10）。
 *   · 点卡片 → 由 Index.ets 统一负责详情路由（本页只上抛 memberId）。
 *
 * 权限：名录全社团可见（服务端 ViewMembers 对所有 active 成员放行），本页不做权限隐藏。
 */
import { MemberApi } from '../api/MemberApi'
import type { MemberListParams } from '../api/MemberApi'
import type { MemberBrief } from '../api/AuthApi'
import { DeptApi } from '../api/DeptApi'
import type { DeptView } from '../api/DeptApi'
import { MemberCard } from '../components/MemberCard'
import { Color, FontSize, Radius, Space, StatusColor } from '../core/Theme'
import { can, PermissionStore } from '../store/PermissionStore'
import { pushTo } from '../utils/RouterUtils'

/** 名录里的一个分组（对应设计稿 P06 的一个 section） */
interface DeptGroup {
  deptId: number
  deptName: string
  /** 服务端 deptView.member_count（该部门 active 成员数） */
  serverCount: number
  /** 当前这轮请求实际拿到的成员（搜索时为命中子集） */
  members: MemberBrief[]
}

/** 服务端 page size 上限 200（paging.cj） */
const PAGE_SIZE: number = 200
/** 兜底上限：最多 20 页（4000 人），防止异常 total 把循环卡死 */
const MAX_PAGES: number = 20
/** 搜索防抖：输入停止 300ms 后才打接口 */
const SEARCH_DEBOUNCE_MS: number = 300

@Component
export default struct MemberListPage {
  onMemberClick: (memberId: number) => void = (_id: number) => {}
  /** 由 Index.ets 在切 Tab / 详情页改动数据后自增，触发重新拉取 */
  @Prop @Watch('onRefreshSignal') refreshSignal: number = 0

  @State groups: DeptGroup[] = []
  @State keyword: string = ''
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State activeTotal: number = 0
  @State pendingTotal: number = 0

  private memberApi: MemberApi = new MemberApi()
  private deptApi: DeptApi = new DeptApi()
  /** 部门列表（分组顺序权威来源），失败时退化为「按成员自带部门分组」 */
  private depts: DeptView[] = []
  private searchTimer: number = -1

  aboutToAppear(): void {
    this.load()
  }

  onRefreshSignal(): void {
    this.load()
  }

  aboutToDisappear(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer)
      this.searchTimer = -1
    }
  }

  // ─── 数据加载 ───

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    await this.loadDepts()
    await this.loadMembers()
    await this.loadPendingTotal()
    this.loading = false
  }

  /** GET /depts —— 分组顺序 + 每组人数（服务端只算 active） */
  private async loadDepts(): Promise<void> {
    const resp = await this.deptApi.list()
    if (resp.ok && resp.data !== undefined) {
      this.depts = resp.data.items
    } else {
      this.depts = []
      this.errorMsg = resp.error?.message ?? '加载组织失败'
    }
  }

  /**
   * GET /members?status=active —— 分页循环拉全。
   * 为什么循环：服务端 page size 有上限 200，而容量目标是「近千人」，
   * 单页拿不全（评审 D-10 已记录；服务端如提供分组接口可换掉这段）。
   */
  private async loadMembers(): Promise<void> {
    const collected: MemberBrief[] = []
    let total: number = 0
    let page: number = 1
    let failed: boolean = false

    while (page <= MAX_PAGES) {
      const params: MemberListParams = { status: 'active', page: page, size: PAGE_SIZE }
      if (this.keyword.length > 0) {
        params.q = this.keyword
      }
      const resp = await this.memberApi.list(params)
      if (!resp.ok || resp.data === undefined) {
        this.errorMsg = resp.error?.message ?? '加载成员名录失败'
        failed = true
        break
      }
      total = resp.data.total
      for (let i = 0; i < resp.data.items.length; i++) {
        collected.push(resp.data.items[i])
      }
      if (resp.data.items.length < PAGE_SIZE) {
        break
      }
      page += 1
    }

    if (failed) {
      this.groups = []
      return
    }
    this.activeTotal = total
    this.groups = this.buildGroups(collected)
    this.errorMsg = ''
  }

  /** 只取待分配人数：size=1，不传输名单（P06 页眉「待分配 N 人」） */
  private async loadPendingTotal(): Promise<void> {
    const resp = await this.memberApi.list({ status: 'pending', size: 1 })
    if (resp.ok && resp.data !== undefined) {
      this.pendingTotal = resp.data.total
    }
  }

  /**
   * 按 GET /depts 的顺序分组。
   * 搜索时丢掉「零命中」的分组，避免整页都是空 section。
   */
  private buildGroups(items: MemberBrief[]): DeptGroup[] {
    const result: DeptGroup[] = []
    const searching: boolean = this.keyword.length > 0

    for (let i = 0; i < this.depts.length; i++) {
      const dept: DeptView = this.depts[i]
      const members: MemberBrief[] = items.filter((m: MemberBrief): boolean => {
        return m.dept !== null && m.dept !== undefined && m.dept.id === dept.id
      })
      if (searching && members.length === 0) {
        continue
      }
      result.push({
        deptId: dept.id,
        deptName: dept.name,
        serverCount: dept.member_count,
        members: members,
      })
    }

    // active 成员理论上必有部门；真拿到 dept=null 的也不藏起来
    const orphans: MemberBrief[] = items.filter((m: MemberBrief): boolean => {
      return m.dept === null || m.dept === undefined
    })
    if (orphans.length > 0) {
      result.push({
        deptId: -1,
        deptName: '未分配部门',
        serverCount: orphans.length,
        members: orphans,
      })
    }

    // 部门表整个拿不到时的降级：按成员自带部门顺序分组，保证页面仍可用
    if (result.length === 0 && items.length > 0) {
      return this.buildGroupsFromMembers(items)
    }
    return result
  }

  /** 降级分组：不依赖 /depts，部门顺序按成员返回顺序。 */
  private buildGroupsFromMembers(items: MemberBrief[]): DeptGroup[] {
    const result: DeptGroup[] = []
    for (let i = 0; i < items.length; i++) {
      const dept = items[i].dept
      if (dept === null || dept === undefined) {
        continue
      }
      const hit = result.find((g: DeptGroup): boolean => g.deptId === dept.id)
      if (hit !== undefined) {
        hit.members.push(items[i])
      } else {
        result.push({ deptId: dept.id, deptName: dept.name, serverCount: 0, members: [items[i]] })
      }
    }
    for (let i = 0; i < result.length; i++) {
      result[i].serverCount = result[i].members.length
    }
    return result
  }

  // ─── 搜索 ───

  private onKeywordChange(value: string): void {
    this.keyword = value
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer)
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1
      this.loadMembers()
    }, SEARCH_DEBOUNCE_MS)
  }

  private clearKeyword(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer)
      this.searchTimer = -1
    }
    this.keyword = ''
    this.loadMembers()
  }

  // ─── 展示辅助 ───

  /** 页眉「N 个组织」：以当前可见（非空）分组计数，与设计稿的「4 个组织」口径一致。 */
  private visibleGroupCount(): number {
    return this.groups.filter((g: DeptGroup): boolean => g.members.length > 0).length
  }

  private shownTotal(): number {
    let sum: number = 0
    for (let i = 0; i < this.groups.length; i++) {
      sum += this.groups[i].members.length
    }
    return sum
  }

  private headerCountLine(): string {
    if (this.keyword.length > 0) {
      return `「${this.keyword}」命中 ${this.shownTotal()} 位 · ${this.visibleGroupCount()} 个组织`
    }
    return `${this.activeTotal} 位成员 · ${this.visibleGroupCount()} 个组织`
  }

  private groupCountText(group: DeptGroup): string {
    if (this.keyword.length > 0) {
      return `${group.members.length} 位命中`
    }
    return `${group.serverCount} 人`
  }

  /** 页眉「管理 ›」入口显隐：与管理页 AdminPage 的准入口径一致。 */
  private canOpenManage(): boolean {
    const u = PermissionStore.getInstance().userInfo
    return can(u, 'ManageDepts') || can(u, 'ViewRegisterCode') ||
      can(u, 'ChangeRegisterCode') || can(u, 'ManageInviteLinks') ||
      can(u, 'TransferPresidency')
  }

  // ─── UI ───

  @Builder
  pageHeader() {
    Column({ space: 4 }) {
      Row() {
        Text('成员名录')
          .fontSize(FontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
          .layoutWeight(1)

        if (this.canOpenManage()) {
          Text('管理 ›')
            .fontSize(FontSize.body)
            .fontColor(Color.primary)
            .onClick(() => {
              pushTo('pages/AdminPage')
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(this.headerCountLine())
          .fontSize(FontSize.caption)
          .fontColor(Color.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('全社团可见')
          .fontSize(FontSize.micro)
          .fontColor(Color.textTertiary)
      }
      .width('100%')

      if (this.pendingTotal > 0 && this.keyword.length === 0) {
        Text(`另有待分配 ${this.pendingTotal} 人（待管理员分配后进入名录）`)
          .fontSize(FontSize.micro)
          .fontColor(StatusColor.pending.fg)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })
  }

  @Builder
  searchBar() {
    Row() {
      TextInput({ text: this.keyword, placeholder: '搜索姓名或部门' })
        .placeholderColor(Color.textTertiary)
        .placeholderFont({ size: FontSize.body })
        .fontSize(FontSize.body)
        .fontColor(Color.textPrimary)
        .backgroundColor('#00000000')
        .borderRadius(0)
        .padding({ left: Space.sm, right: Space.sm })
        .height(40)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.onKeywordChange(value)
        })

      if (this.keyword.length > 0) {
        Image($r('app.media.icon_cross'))
          .width(16)
          .height(16)
          .onClick(() => {
            this.clearKeyword()
          })
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: Space.md, right: Space.md })
    .backgroundColor(Color.control)
    .borderRadius(Radius.input)
    .margin({ left: Space.page, right: Space.page, bottom: Space.sm })
  }

  @Builder
  statusHint() {
    if (this.loading && this.groups.length === 0) {
      Column({ space: Space.md }) {
        LoadingProgress().width(32).height(32).color(Color.primary)
        Text('正在加载名录…')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
      .width('100%')
      .padding({ top: Space.xxl * 2, bottom: Space.xxl })
    } else if (this.errorMsg.length > 0 && this.groups.length === 0) {
      Column({ space: Space.md }) {
        Text(this.errorMsg)
          .fontSize(FontSize.caption)
          .fontColor(StatusColor.overdue.fg)
          .textAlign(TextAlign.Center)
          .width('100%')

        Button('重试')
          .height(36)
          .fontSize(FontSize.body)
          .fontColor(Color.onPrimary)
          .backgroundColor(Color.primary)
          .borderRadius(Radius.button)
          .onClick(() => {
            this.load()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl, bottom: Space.xxl, left: Space.page, right: Space.page })
    }
  }

  @Builder
  emptyHint(text: string) {
    Text(text)
      .fontSize(FontSize.caption)
      .fontColor(Color.textTertiary)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: Space.xl, bottom: Space.xl })
  }

  @Builder
  groupSection(group: DeptGroup) {
    Column({ space: Space.sm }) {
      Text(`${group.deptName} · ${this.groupCountText(group)}`)
        .fontSize(FontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.textPrimary)
        .width('100%')
        .padding({ left: Space.xs, right: Space.xs })

      if (group.members.length > 0) {
        Column() {
          ForEach(group.members, (member: MemberBrief, index: number) => {
            if (index > 0) {
              Divider()
                .strokeWidth(1)
                .color(Color.divider)
            }
            MemberCard({
              member: member,
              onCardClick: () => {
                this.onMemberClick(member.id)
              }
            })
          }, (member: MemberBrief): string => `${member.id}`)
        }
        .width('100%')
        .backgroundColor(Color.surface)
        .borderRadius(Radius.card)
        .border({ width: 1, color: Color.border })
      } else {
        Text('该组织暂无成员。')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')
          .padding({ left: Space.xs, top: Space.sm, bottom: Space.sm })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.pageHeader()
      this.searchBar()

      Scroll() {
        Column({ space: Space.section }) {
          this.statusHint()

          // 整页一条都没有时只给一句空态，不渲染「4 个空 section」
          if (!this.loading && this.errorMsg.length === 0 && this.shownTotal() === 0) {
            this.emptyHint(this.keyword.length > 0
              ? `没有匹配「${this.keyword}」的成员，换个姓名或部门名试试。`
              : '社团还没有成员。')
          }

          if (this.shownTotal() > 0) {
            ForEach(this.groups, (group: DeptGroup) => {
              this.groupSection(group)
            }, (group: DeptGroup): string => `${group.deptId}`)

            Text('名录不含手机号——这是隐私最小化')
              .fontSize(FontSize.micro)
              .fontColor(Color.textTertiary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: Space.sm })
          }
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: 110 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
