/**
 * 作者：刘运泽
 * 功能：任务详情页（状态机 + 阻塞原因 + 日历同步 + 删除）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  任务接入系统日历同步
 *   2026-09-17  编辑与移动 + 日历对账接线
 *   2026-09-17  恢复设计稿外观
 *   2026-09-18  按 Figma 还原：白色头部（返回+···）、信息卡（徽章在上/负责人·部门·角色/所属课题蓝链/截止·逾期）
 */
// 任务详情。切到 blocked 必须填原因，否则后端返回 BLOCKER_REQUIRED。
// 状态保存走 PUT /tasks/{id}/status，删除走 DELETE /tasks/{id}。

import router from '@ohos.router'
import { TaskApi, TaskDetail, TaskStatus, PlanRef, UpdateTaskStatusRequest } from '../api/TaskApi'
import { StatusChip } from '../components/StatusChip'
import { SegmentedControl } from '../components/SegmentedControl'
import { Color, FontSize, Radius, Space, StatusColor, roleLabel } from '../core/Theme'
import { CalendarSyncService } from '../util/CalendarSync'
import { AiApi, NoticeDraft, Retrospective, RetroCause, AiSource } from '../api/AiApi'
import { pasteboard } from '@kit.BasicServicesKit'
import { promptAction } from '@kit.ArkUI'

const EMPTY_TASK_DETAIL: TaskDetail = {
  id: 0,
  title: '',
  status: 'todo',
  owner: null,
  dept: null,
  plan: null,
  due_at: null,
  is_overdue: false,
  blocked: false,
  updated_at: '',
  desc: '',
  blocker: null,
  plan_path: [],
  created_by: null,
  created_at: '',
  completed_at: null
}

interface TaskDetailParams {
  task_id?: number
}

@Entry
@Component
struct TaskDetailPage {
  @State detail: TaskDetail = EMPTY_TASK_DETAIL
  @State currentStatus: string = 'todo'
  @State blockerText: string = ''
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State segIndex: number = 0
  // 起草通知弹窗（可编辑/复制，不做发送，见 docs/llm-frontend-guide.md §3）
  @State showNotice: boolean = false
  @State notice: NoticeDraft | null = null
  @State noticeSource: AiSource = 'none'
  @State noticeLoading: boolean = false
  @State noticeTitle: string = ''
  @State noticeBody: string = ''
  // 成效与延期（折叠区块，含归因 + 改进建议）
  @State retro: Retrospective | null = null
  @State retroSource: AiSource = 'none'
  @State retroLoading: boolean = false
  @State retroOpen: boolean = false
  @State retroFetched: boolean = false

  private taskApi: TaskApi = new TaskApi()
  private calendarSync: CalendarSyncService = CalendarSyncService.getInstance()
  private aiApi: AiApi = new AiApi()
  private statusValues: string[] = ['todo', 'doing', 'blocked', 'done']
  private statusLabels: string[] = ['未开始', '进行中', '阻塞', '已完成']
  private isActive: boolean = true
  private noticeSeq: number = 0
  private retroSeq: number = 0

  aboutToAppear(): void {
    const p = router.getParams() as TaskDetailParams
    if (p !== undefined && p !== null && p.task_id !== undefined) {
      this.load(p.task_id)
    } else {
      this.loading = false
      this.errorMsg = '缺少任务 id'
    }
  }

  aboutToDisappear(): void {
    this.isActive = false
  }

  private async load(taskId: number): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.detail(taskId)
    if (resp.ok && resp.data) {
      this.detail = resp.data
      this.currentStatus = resp.data.status
      this.blockerText = resp.data.blocker ?? ''
      const idx = this.statusValues.indexOf(resp.data.status)
      this.segIndex = idx >= 0 ? idx : 0
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private onSegChange(i: number): void {
    this.segIndex = i
    this.currentStatus = this.statusValues[i]
    if (this.currentStatus !== 'blocked') {
      this.blockerText = ''
    }
  }

  private async save(): Promise<void> {
    const data: UpdateTaskStatusRequest = { status: this.currentStatus as TaskStatus }
    if (this.currentStatus === 'blocked') {
      data.blocker = this.blockerText
    }
    const resp = await this.taskApi.updateStatus(this.detail.id, data)
    if (resp.ok && resp.data) {
      this.detail = resp.data
      this.currentStatus = resp.data.status
      this.blockerText = resp.data.blocker ?? ''
      const idx = this.statusValues.indexOf(resp.data.status)
      this.segIndex = idx >= 0 ? idx : 0
      if (resp.data.status === 'done') {
        this.calendarSync.removeTask(this.detail.id, getContext(this))
      }
      AlertDialog.show({ message: '已保存' })
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '保存失败' })
    }
  }

  private async addToCalendar(): Promise<void> {
    if (this.detail.due_at === null || this.detail.status === 'done') {
      AlertDialog.show({ message: '该任务无截止时间或已完成，无需加入日历' })
      return
    }
    const msg = await this.calendarSync.addOrUpdateTask(this.detail, getContext(this))
    AlertDialog.show({ message: msg })
  }

  private async doDelete(): Promise<void> {
    const resp = await this.taskApi.delete_(this.detail.id)
    if (resp.ok) {
      await this.calendarSync.removeTask(this.detail.id, getContext(this))
      router.back()
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '删除失败' })
    }
  }

  private ownerLabel(): string {
    const o = this.detail.owner
    if (o === null) {
      return '未分配'
    }
    const dept: string = o.dept?.name ?? ''
    const role: string = roleLabel(o.role)
    return dept.length > 0 ? `${o.name} · ${dept} · ${role}` : `${o.name} · ${role}`
  }

  private planPath(): string {
    if (this.detail.plan_path.length > 0) {
      return this.detail.plan_path.map((p: PlanRef) => p.title).join(' › ')
    }
    return this.detail.plan !== null ? this.detail.plan.title : '独立任务'
  }

  private dueText(): string {
    if (this.detail.due_at === null) {
      return '无'
    }
    const days: number = this.detail.overdue_days ?? 0
    return this.detail.is_overdue ? `${this.detail.due_at} · 逾期 ${days} 天` : this.detail.due_at
  }

  private overdueBanner(): string {
    const days: number = this.detail.overdue_days ?? 0
    const prefix: string = days > 0 ? `已逾期 ${days} 天` : '已逾期'
    return `${prefix} · 该判断由服务端算出，客户端不重算`
  }

  private needsHelpLabel(): string {
    const nh = this.detail.needs_help
    if (nh === undefined || nh === null) {
      return ''
    }
    const deptName: string = nh.dept?.name ?? ''
    const memberName: string = nh.member?.name ?? ''
    if (memberName.length > 0) {
      return deptName.length > 0 ? `${deptName} ${memberName}` : memberName
    }
    return deptName
  }

  // ── 起草通知（可编辑/复制，不做发送，见 docs/llm-frontend-guide.md §3） ──

  private audienceLabel(a: string): string {
    if (a === 'leads') return '负责人'
    if (a === 'all') return '全员'
    return '成员'
  }

  private noticeBadge(): string {
    if (this.noticeSource === 'model') return 'AI 建议'
    if (this.noticeSource === 'fallback') return '依据历史数据'
    return '起草通知暂不可用'
  }

  private openNotice(): void {
    this.showNotice = true
    if (this.notice === null) {
      this.loadNotice()
    }
  }

  private async loadNotice(): Promise<void> {
    if (this.noticeLoading) return // 防重复点击
    this.noticeLoading = true
    const seq = ++this.noticeSeq
    let timedOut = false
    const timer: number = setTimeout(() => {
      timedOut = true
      if (seq === this.noticeSeq && this.isActive) {
        this.notice = null
        this.noticeSource = 'none'
        this.noticeLoading = false
      }
    }, 20000)
    const resp = await this.aiApi.noticeDraft(this.detail.id, 'members')
    clearTimeout(timer)
    if (timedOut || seq !== this.noticeSeq || !this.isActive) return // 离开/超时丢弃回填
    this.noticeLoading = false
    if (resp.ok && resp.data) {
      this.notice = resp.data
      this.noticeSource = resp.data.source
      this.noticeTitle = resp.data.title
      this.noticeBody = resp.data.body
    } else {
      this.notice = null
      this.noticeSource = 'none'
    }
  }

  private copyNotice(): void {
    if (this.notice === null) return
    const parts: string[] = []
    parts.push(this.noticeTitle.length > 0 ? this.noticeTitle : this.notice.title)
    parts.push('')
    parts.push(this.noticeBody.length > 0 ? this.noticeBody : this.notice.body)
    const meta: string[] = [`受众：${this.audienceLabel(this.notice.audience)}`]
    if (this.notice.suggest_send_at !== null) {
      meta.push(`建议发送：${this.notice.suggest_send_at}`)
    }
    parts.push('')
    parts.push(meta.join(' · '))
    this.copyToClipboard(parts.join('\n'))
  }

  private copyToClipboard(text: string): void {
    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
    pasteboard.getSystemPasteboard().setData(pasteData)
      .then(() => {
        promptAction.showToast({ message: '已复制到剪贴板' })
      })
      .catch((e: Error) => {
        console.error(`copy failed: ${e.message}`)
      })
  }

  // ── 成效与延期（折叠区块，含归因 + 改进建议） ──

  private causeKindLabel(kind: string): string {
    if (kind === 'dependency') return '依赖上游'
    if (kind === 'overload') return '负载过高'
    if (kind === 'granularity') return '拆分过粗'
    if (kind === 'scope_drift') return '范围蔓延'
    if (kind === 'external') return '外部因素'
    return '其他'
  }

  private retroBadge(): string {
    if (this.retroSource === 'model') return 'AI 建议'
    if (this.retroSource === 'fallback') return '依据历史数据'
    return '成效分析暂不可用'
  }

  private toggleRetro(): void {
    this.retroOpen = !this.retroOpen
    if (this.retroOpen && this.retro === null && !this.retroFetched) {
      this.loadRetro()
    }
  }

  private async loadRetro(): Promise<void> {
    if (this.retroLoading) return
    this.retroLoading = true
    const seq = ++this.retroSeq
    let timedOut = false
    const timer: number = setTimeout(() => {
      timedOut = true
      if (seq === this.retroSeq && this.isActive) {
        this.retro = null
        this.retroSource = 'none'
        this.retroFetched = true
        this.retroLoading = false
      }
    }, 20000)
    const resp = await this.aiApi.retrospective({ taskId: this.detail.id })
    clearTimeout(timer)
    if (timedOut || seq !== this.retroSeq || !this.isActive) return
    this.retroLoading = false
    if (resp.ok && resp.data) {
      this.retro = resp.data
      this.retroSource = resp.data.source
    } else {
      this.retro = null
      this.retroSource = 'none'
    }
    this.retroFetched = true
  }

  @Builder
  noticeDialog() {
    Column() {
      Column() {
        Row() {
          Text('起草通知')
            .fontSize(FontSize.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.textPrimary)
          Blank()
          Text('关闭')
            .fontSize(FontSize.caption)
            .fontColor(Color.textTertiary)
            .onClick(() => {
              this.showNotice = false
            })
        }
        .width('100%')

        if (this.noticeLoading) {
          Row() {
            LoadingProgress().width(22).height(22).color(Color.primary)
            Text('正在起草…')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ left: Space.sm })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: Space.lg, bottom: Space.lg })
        } else if (this.notice === null) {
          Column() {
            Text('起草通知暂不可用')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .width('100%')
              .textAlign(TextAlign.Center)
            Button('重试')
              .height(32)
              .fontSize(FontSize.caption)
              .backgroundColor(Color.surface)
              .fontColor(Color.primary)
              .border({ width: 1, color: Color.primary })
              .margin({ top: Space.sm })
              .onClick(() => { this.loadNotice() })
          }
          .width('100%')
          .padding({ top: Space.lg, bottom: Space.lg })
        } else {
          Row() {
            Text(this.noticeBadge())
              .fontSize(FontSize.micro)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.noticeSource === 'model' ? Color.primary : Color.textTertiary)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.noticeSource === 'model' ? Color.primarySoft : Color.control)
              .borderRadius(Radius.pill)
          }
          .width('100%')
          .margin({ top: Space.sm })

          TextInput({ text: this.noticeTitle, placeholder: '标题' })
            .fontSize(FontSize.body)
            .fontColor(Color.textPrimary)
            .backgroundColor('#F9FAFB')
            .borderRadius(Radius.input)
            .padding({ left: Space.md, right: Space.md })
            .height(44)
            .width('100%')
            .margin({ top: Space.sm })
            .onChange((v: string) => { this.noticeTitle = v })

          TextArea({ text: this.noticeBody, placeholder: '正文' })
            .fontSize(FontSize.body)
            .fontColor(Color.textPrimary)
            .backgroundColor('#F9FAFB')
            .borderRadius(Radius.input)
            .padding(Space.md)
            .height(180)
            .width('100%')
            .margin({ top: Space.sm })
            .onChange((v: string) => { this.noticeBody = v })

          Text(`受众：${this.audienceLabel(this.notice.audience)}${this.notice.suggest_send_at !== null ? ' · 建议发送：' + this.notice.suggest_send_at : ''}`)
            .fontSize(FontSize.caption)
            .fontColor(Color.textTertiary)
            .width('100%')
            .margin({ top: Space.sm })

          Row({ space: Space.md }) {
            Button('一键复制')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(Color.primary)
              .fontColor(Color.surface)
              .onClick(() => { this.copyNotice() })
            Button('关闭')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(Color.surface)
              .fontColor(Color.textSecondary)
              .border({ width: 1, color: Color.border })
              .onClick(() => { this.showNotice = false })
          }
          .width('100%')
          .margin({ top: Space.md })
        }
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor(Color.surface)
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  retroCard() {
    Column() {
      Row() {
        Text('成效与延期')
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.textPrimary)
        Blank()
        Text(this.retroOpen ? '收起' : '展开')
          .fontSize(FontSize.caption)
          .fontColor(this.retroOpen ? Color.textTertiary : Color.primary)
      }
      .width('100%')
      .padding(Space.card)
      .onClick(() => { this.toggleRetro() })

      if (this.retroOpen) {
        if (this.retroLoading) {
          Row() {
            LoadingProgress().width(22).height(22).color(Color.primary)
            Text('正在生成分析…')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ left: Space.sm })
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, bottom: Space.card })
        } else if (this.retro === null) {
          Column() {
            Text('成效分析暂不可用')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .width('100%')
            Button('重试')
              .height(32)
              .fontSize(FontSize.caption)
              .backgroundColor(Color.surface)
              .fontColor(Color.primary)
              .border({ width: 1, color: Color.primary })
              .margin({ top: Space.sm })
              .onClick(() => { this.loadRetro() })
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, bottom: Space.card })
        } else {
          Column({ space: Space.sm }) {
            Row() {
              Text(this.retroBadge())
                .fontSize(FontSize.micro)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.retroSource === 'model' ? Color.primary : Color.textTertiary)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor(this.retroSource === 'model' ? Color.primarySoft : Color.control)
                .borderRadius(Radius.pill)
            }
            .width('100%')

            Text(this.retro.summary)
              .fontSize(FontSize.body)
              .fontColor(Color.textPrimary)
              .lineHeight(20)
              .width('100%')

            if (this.retro.overdue.is_overdue) {
              Column() {
                Text(`延期 ${this.retro.overdue.days} 天 · 归因`)
                  .fontSize(FontSize.caption)
                  .fontColor(Color.textTertiary)
                  .width('100%')
                ForEach(this.retro.overdue.causes, (c: RetroCause, idx: number) => {
                  Row() {
                    Text(this.causeKindLabel(c.kind))
                      .fontSize(FontSize.micro)
                      .fontColor(Color.textSecondary)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor(Color.control)
                      .borderRadius(4)
                    Text(c.detail)
                      .fontSize(FontSize.body)
                      .fontColor(Color.textPrimary)
                      .layoutWeight(1)
                      .margin({ left: Space.sm })
                  }
                  .width('100%')
                  .margin({ top: 2 })
                }, (c: RetroCause, idx: number) => `${idx}_${c.kind}`)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }

            if (this.retro.suggestions.length > 0) {
              Column() {
                Text('改进建议')
                  .fontSize(FontSize.caption)
                  .fontColor(Color.textTertiary)
                  .width('100%')
                ForEach(this.retro.suggestions, (s: string, idx: number) => {
                  Text(`· ${s}`)
                    .fontSize(FontSize.body)
                    .fontColor(Color.textPrimary)
                    .lineHeight(20)
                    .width('100%')
                    .margin({ top: 2 })
                }, (s: string, idx: number) => `${idx}_${s}`)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, bottom: Space.card })
        }
      }
    }
    .width('100%')
    .backgroundColor(this.retroSource === 'fallback' ? Color.canvas : Color.surface)
    .borderRadius(Radius.card)
    .border({ width: 1, color: this.retroSource === 'fallback' ? Color.divider : Color.border })
  }

  @Builder
  header() {
    Row() {
      Image($r('app.media.icon_chevron_left_primary'))
        .width(20)
        .height(20)
        .onClick(() => {
          router.back()
        })
      Text('任务详情')
        .fontSize(FontSize.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.textPrimary)
        .margin({ left: Space.sm })
      Blank()
      Image($r('app.media.icon_more'))
        .width(20)
        .height(20)
    }
    .width('100%')
    .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.md })
    .backgroundColor(Color.surface)
    .border({ width: 1, color: Color.divider })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(FontSize.caption).fontColor(Color.textTertiary).width(72)
      Text(value).fontSize(FontSize.body).fontColor(Color.textPrimary).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: Space.xs, bottom: Space.xs })
  }

  @Builder
  planRow() {
    Row() {
      Text('所属课题').fontSize(FontSize.caption).fontColor(Color.textTertiary).width(72)
      Text(this.planPath())
        .fontSize(FontSize.body)
        .fontColor(Color.primary)
        .layoutWeight(1)
        .onClick(() => {
          if (this.detail.plan !== null) {
            router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: this.detail.plan.id } })
          }
        })
    }
    .width('100%')
    .padding({ top: Space.xs, bottom: Space.xs })
  }

  @Builder
  statusHint() {
    if (this.loading) {
      Row() {
        LoadingProgress().width(28).height(28).color(Color.primary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: Space.xxl, bottom: Space.xxl })
    } else if (this.errorMsg.length > 0) {
      Column() {
        Text(this.errorMsg)
          .fontSize(FontSize.caption)
          .fontColor(StatusColor.overdue.fg)
          .width('100%')
          .textAlign(TextAlign.Center)
        Button('重试')
          .height(36)
          .backgroundColor(Color.primary)
          .fontColor(Color.surface)
          .margin({ top: Space.sm })
          .onClick(() => {
            const p = router.getParams() as TaskDetailParams
            if (p !== undefined && p !== null && p.task_id !== undefined) {
              this.load(p.task_id)
            }
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      this.header()

      if (this.loading || this.errorMsg.length > 0) {
        this.statusHint()
      } else {
        Scroll() {
          Column({ space: Space.md }) {
            // ── 信息卡：徽章在上 → 标题 → 负责人/所属课题/截止 ──
            Column() {
              Row({ space: Space.sm }) {
                if (this.detail.is_overdue) {
                  StatusChip({ status: 'overdue', isOverdue: true })
                }
                if (this.detail.status === 'blocked') {
                  StatusChip({ status: 'blocked', isOverdue: false })
                }
              }
              .width('100%')

              Text(this.detail.title)
                .fontSize(FontSize.title)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.textPrimary)
                .width('100%')
                .margin({ top: Space.sm })

              Column() {
                this.infoRow('负责人', this.ownerLabel())
                this.planRow()
                this.infoRow('截止', this.dueText())
              }
              .width('100%')
              .margin({ top: Space.sm })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            // ── 逾期提醒 ──
            if (this.detail.is_overdue) {
              Text(this.overdueBanner())
                .fontSize(FontSize.caption)
                .fontColor(StatusColor.overdue.fg)
                .width('100%')
                .padding(Space.md)
                .backgroundColor(StatusColor.overdue.bg)
                .borderRadius(Radius.input)
            }

            // ── 状态控制：分段 + 阻塞原因输入 + 保存 ──
            Column() {
              Text('更新状态').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              SegmentedControl({ options: this.statusLabels, selectedIndex: this.segIndex, onChange: (i: number) => { this.onSegChange(i) } })
                .margin({ top: Space.sm })

              if (this.currentStatus === 'blocked') {
                TextInput({ placeholder: '阻塞原因（必填）', text: this.blockerText })
                  .onChange((v: string) => {
                    this.blockerText = v
                  })
                  .height(44)
                  .backgroundColor(Color.surface)
                  .borderRadius(Radius.input)
                  .margin({ top: Space.sm })
              }

              Button('保存修改')
                .width('100%')
                .height(46)
                .backgroundColor(Color.primary)
                .enabled(this.currentStatus !== 'blocked' || this.blockerText.length > 0)
                .margin({ top: Space.md })
                .onClick(() => {
                  this.save()
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            // ── 阻塞原因展示 ──
            if (this.currentStatus === 'blocked' && this.blockerText.length > 0) {
              Column() {
                Text('阻塞原因（进入 blocked 必填）')
                  .fontSize(FontSize.micro)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(StatusColor.blocked.fg)
                  .width('100%')
                Text(this.blockerText)
                  .fontSize(FontSize.body)
                  .fontColor(Color.blockerFg)
                  .lineHeight(20)
                  .width('100%')
                  .margin({ top: 3 })
                if (this.needsHelpLabel().length > 0) {
                  Text(`需要帮助 · ${this.needsHelpLabel()}`)
                    .fontSize(FontSize.body)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(StatusColor.blocked.fg)
                    .width('100%')
                    .margin({ top: Space.xs })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(Space.md)
              .backgroundColor(StatusColor.blocked.bg)
              .borderRadius(Radius.input)
            }

            // ── 描述 ──
            Column() {
              Text('描述').fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              Text(this.detail.desc).fontSize(FontSize.body).fontColor(Color.textPrimary).width('100%').margin({ top: Space.xs })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            // ── 成效与延期（折叠区块，含归因 + 改进建议） ──
            this.retroCard()

            // ── 起草通知（可编辑/复制，不做发送） ──
            Button('起草通知')
              .width('100%')
              .height(44)
              .backgroundColor(Color.surface)
              .border({ width: 1, color: Color.primary })
              .fontColor(Color.primary)
              .onClick(() => { this.openNotice() })

            // ── 编辑任务（保留功能） ──
            Button('编辑任务')
              .width('100%')
              .height(44)
              .backgroundColor(Color.surface)
              .border({ width: 1, color: Color.border })
              .fontColor(Color.primary)
              .onClick(() => {
                router.pushUrl({ url: 'pages/CreateTaskPage', params: { task_id: this.detail.id } })
              })

            // ── 操作：加入系统日历 + 删除任务 ──
            Row({ space: Space.md }) {
              Button('加入系统日历')
                .layoutWeight(1)
                .height(46)
                .backgroundColor(Color.surface)
                .border({ width: 1, color: Color.primary })
                .fontColor(Color.primary)
                .onClick(() => {
                  this.addToCalendar()
                })
              Button('删除任务')
                .layoutWeight(1)
                .height(46)
                .backgroundColor(Color.surface)
                .border({ width: 1, color: Color.border })
                .fontColor(Color.textSecondary)
                .onClick(() => {
                  AlertDialog.show({
                    title: '删除任务',
                    message: '删除后不可恢复，确认删除？',
                    primaryButton: {
                      value: '取消',
                      action: () => {}
                    },
                    secondaryButton: {
                      value: '删除',
                      action: () => {
                        this.doDelete()
                      }
                    }
                  })
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
    .bindContentCover(this.showNotice, this.noticeDialog)
  }
}
