/**
 * 作者：刘运泽
 * 功能：新建/编辑任务页（POST / PATCH，client_token 防重）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  截止时间改为日期+时间选择器
 *   2026-09-17  编辑与移动 + 日历对账接线
 *   2026-09-17  恢复设计稿外观
 */
// 新建任务。创建走 POST /tasks，带 client_token（UUID）防重复提交。
// 负责人/所属课题下拉来自 MemberApi / PlanApi。

import router from '@ohos.router'
import { TaskApi, CreateTaskRequest, UpdateTaskRequest, PlanRef } from '../api/TaskApi'
import { MemberApi } from '../api/MemberApi'
import { PlanApi } from '../api/PlanApi'
import { MemberBrief } from '../api/AuthApi'
import { flattenPlans } from '../util/PlanTree'
import { genClientToken } from '../util/ClientToken'
import { formatYmdHm } from '../util/DateFmt'
import { AiApi, TaskSuggestion, AiSource } from '../api/AiApi'
import { Color, FontSize, Radius, Space } from '../core/Theme'

interface CreateTaskParams {
  task_id?: number
}

@Entry
@Component
struct CreateTaskPage {
  @State title: string = ''
  @State desc: string = ''
  @State ownerId: number = 0
  @State planId: number = 0
  @State dueAt: string = ''
  @State showOwnerPicker: boolean = false
  @State showPlanPicker: boolean = false
  @State members: MemberBrief[] = []
  @State plansFlat: PlanRef[] = []
  @State submitting: boolean = false
  @State isEdit: boolean = false
  @State editingId: number = 0
  // 智能建议卡片状态（默认折叠，见 docs/llm-frontend-guide.md §3）
  @State suggestion: TaskSuggestion | null = null
  @State suggestionSource: AiSource = 'none'
  @State suggestionLoading: boolean = false
  @State suggestionOpen: boolean = false
  @State suggestionFetched: boolean = false
  @State suggestionIgnored: boolean = false

  private taskApi: TaskApi = new TaskApi()
  private memberApi: MemberApi = new MemberApi()
  private planApi: PlanApi = new PlanApi()
  private aiApi: AiApi = new AiApi()
  private isActive: boolean = true
  private suggestionSeq: number = 0

  aboutToAppear(): void {
    const p = router.getParams() as CreateTaskParams
    if (p !== undefined && p !== null && p.task_id !== undefined) {
      this.isEdit = true
      this.editingId = p.task_id
      this.loadTask(p.task_id)
    }
    this.loadOptions()
  }

  aboutToDisappear(): void {
    this.isActive = false
  }

  private async loadTask(id: number): Promise<void> {
    const resp = await this.taskApi.detail(id)
    if (resp.ok && resp.data) {
      this.title = resp.data.title
      this.desc = resp.data.desc
      this.ownerId = resp.data.owner?.id ?? 0
      this.planId = resp.data.plan?.id ?? 0
      this.dueAt = resp.data.due_at ?? ''
    }
  }

  private async loadOptions(): Promise<void> {
    const membersResp = await this.memberApi.list()
    if (membersResp.ok && membersResp.data) {
      this.members = membersResp.data.items
    }
    const plansResp = await this.planApi.list()
    if (plansResp.ok && plansResp.data) {
      this.plansFlat = flattenPlans(plansResp.data.items)
    }
  }

  private ownerName(): string {
    for (const m of this.members) {
      if (m.id === this.ownerId) return m.name
    }
    return '请选择'
  }

  private planName(): string {
    if (this.planId === 0) return '独立任务'
    for (const p of this.plansFlat) {
      if (p.id === this.planId) return p.title
    }
    return '独立任务'
  }

  private pickDueDate(): void {
    const selected = this.dueAt.length > 0 ? new Date(this.dueAt) : new Date();
    DatePickerDialog.show({
      start: new Date('2020-01-01'),
      end: new Date('2035-12-31'),
      selected: selected,
      onDateAccept: (value: Date) => {
        this.pickDueTime(value)
      }
    })
  }

  private pickDueTime(date: Date): void {
    const selected = this.dueAt.length > 0 ? new Date(this.dueAt) : new Date();
    TimePickerDialog.show({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        this.dueAt = formatYmdHm(date, value.hour ?? 0, value.minute ?? 0)
      }
    })
  }

  private async submit(): Promise<void> {
    if (this.submitting) return
    this.submitting = true
    if (this.isEdit) {
      const data: UpdateTaskRequest = {
        title: this.title,
        owner_id: this.ownerId
      }
      if (this.desc.length > 0) data.desc = this.desc
      if (this.planId !== 0) data.plan_id = this.planId
      if (this.dueAt.length > 0) data.due_at = this.dueAt
      const resp = await this.taskApi.update(this.editingId, data)
      this.submitting = false
      if (resp.ok && resp.data) {
        router.back()
      } else {
        AlertDialog.show({
          title: '保存失败',
          message: resp.error?.message ?? '请重试',
          primaryButton: { value: '知道了', action: () => {} }
        })
      }
      return
    }
    const data: CreateTaskRequest = {
      title: this.title,
      owner_id: this.ownerId,
      client_token: genClientToken()
    }
    if (this.desc.length > 0) data.desc = this.desc
    if (this.planId !== 0) data.plan_id = this.planId
    if (this.dueAt.length > 0) data.due_at = this.dueAt
    const resp = await this.taskApi.create(data)
    this.submitting = false
    if (resp.ok && resp.data) {
      router.back()
    } else {
      AlertDialog.show({
        title: '创建失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      })
    }
  }

  // ── 智能建议：默认折叠、逐字段采用 + 全部采用（docs/llm-frontend-guide.md §3） ──

  private suggestionBadge(): string {
    if (this.suggestionSource === 'model') return 'AI 建议'
    if (this.suggestionSource === 'fallback') return '依据历史数据'
    return '智能建议暂不可用'
  }

  private suggestionBadgeFg(): string {
    return this.suggestionSource === 'model' ? Color.primary : Color.textTertiary
  }

  private suggestionCardBg(): string {
    return this.suggestionSource === 'fallback' ? Color.canvas : Color.surface
  }

  // 折叠态紧凑提示：有结果时「AI 建议 · N 条」（N = reasons.length，见 guide §9 决策 1）
  private collapsedTitle(): string {
    const s = this.suggestion
    if (s !== null) {
      return `${this.suggestionBadge()} · ${s.reasons.length} 条`
    }
    return '智能建议'
  }

  private toggleSuggestion(): void {
    this.suggestionOpen = !this.suggestionOpen
    if (this.suggestionOpen && this.suggestion === null && !this.suggestionFetched) {
      this.loadSuggestion()
    }
  }

  private async loadSuggestion(): Promise<void> {
    if (this.suggestionLoading) return // 防重复点击
    this.suggestionLoading = true
    const seq = ++this.suggestionSeq
    let timedOut = false
    // 客户端 20 s 上限，到点按 none 呈现（guide §4）
    const timer: number = setTimeout(() => {
      timedOut = true
      if (seq === this.suggestionSeq && this.isActive) {
        this.suggestion = null
        this.suggestionSource = 'none'
        this.suggestionFetched = true
        this.suggestionLoading = false
      }
    }, 20000)
    const resp = await this.aiApi.taskSuggest({
      title: this.title,
      desc: this.desc.length > 0 ? this.desc : undefined,
      plan_id: this.planId !== 0 ? this.planId : undefined
    })
    clearTimeout(timer)
    if (timedOut || seq !== this.suggestionSeq || !this.isActive) return // 离开/超时丢弃回填
    this.suggestionLoading = false
    if (resp.ok && resp.data) {
      this.suggestion = resp.data
      this.suggestionSource = resp.data.source
    } else {
      // 模型故障不是错误（200+fallback）；真正 4xx 已由 HttpClient 处理，这里统一按 none 呈现，不弹 toast
      this.suggestion = null
      this.suggestionSource = 'none'
    }
    this.suggestionFetched = true
  }

  private adoptOwner(): void {
    const o = this.suggestion?.owner
    if (o !== null && o !== undefined) {
      this.ownerId = o.id
      this.showOwnerPicker = false
    }
  }

  private adoptDue(): void {
    const d = this.suggestion?.due_at
    if (d !== null && d !== undefined && d.length > 0) {
      this.dueAt = d
    }
  }

  private adoptAll(): void {
    this.adoptOwner()
    this.adoptDue()
  }

  // 智能建议三态（model/fallback/none）由本页内联实现（刘运泽），呈现口径见 docs/llm-frontend-guide.md。
  // 逐字段「采用/忽略」交互超出 AiCard 的 title/body/items 契约，故不复用其通用卡片。
  @Builder
  suggestionCard() {
    Column() {
      Row() {
        Text(this.suggestionOpen ? '智能建议' : this.collapsedTitle())
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.textPrimary)
        Blank()
        Text(this.suggestionOpen ? '收起' : '展开')
          .fontSize(FontSize.caption)
          .fontColor(this.suggestionOpen ? Color.textTertiary : Color.primary)
      }
      .width('100%')
      .padding(Space.card)
      .onClick(() => { this.toggleSuggestion() })

      if (this.suggestionOpen) {
        if (this.suggestionLoading) {
          Row() {
            LoadingProgress().width(22).height(22).color(Color.primary)
            Text('正在生成建议…')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ left: Space.sm })
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, bottom: Space.card })
        } else if (this.suggestion !== null) {
          Row() {
            Text(this.suggestionBadge())
              .fontSize(FontSize.micro)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.suggestionBadgeFg())
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.suggestionSource === 'model' ? Color.primarySoft : Color.control)
              .borderRadius(Radius.pill)
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card })

          Row({ space: Space.sm }) {
            Button('全部采用')
              .layoutWeight(1)
              .height(36)
              .fontSize(FontSize.caption)
              .backgroundColor(Color.primary)
              .fontColor(Color.surface)
              .enabled(this.suggestion.owner !== null || this.suggestion.due_at !== null)
              .onClick(() => { this.adoptAll() })
            Button('忽略')
              .layoutWeight(1)
              .height(36)
              .fontSize(FontSize.caption)
              .backgroundColor(Color.surface)
              .fontColor(Color.textSecondary)
              .border({ width: 1, color: Color.border })
              .onClick(() => {
                this.suggestionIgnored = true
                this.suggestionOpen = false
              })
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, top: Space.sm })

          Column({ space: Space.sm }) {
            // 建议负责人
            Row() {
              Column() {
                Text('建议负责人').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                Text(this.suggestion.owner !== null ? this.suggestion.owner.name : '未给出')
                  .fontSize(FontSize.body).fontColor(Color.textPrimary).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('采用')
                .fontSize(FontSize.caption)
                .fontColor(this.suggestion.owner !== null ? Color.primary : Color.textTertiary)
                .padding({ left: Space.md })
                .onClick(() => {
                  const s = this.suggestion
                  if (s !== null && s.owner !== null) {
                    this.adoptOwner()
                  }
                })
            }
            .width('100%')

            // 建议截止时间
            Row() {
              Column() {
                Text('建议截止').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                Text(this.suggestion.due_at !== null ? this.suggestion.due_at : '未给出')
                  .fontSize(FontSize.body).fontColor(Color.textPrimary).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('采用')
                .fontSize(FontSize.caption)
                .fontColor(this.suggestion.due_at !== null ? Color.primary : Color.textTertiary)
                .padding({ left: Space.md })
                .onClick(() => {
                  const s = this.suggestion
                  if (s !== null && s.due_at !== null) {
                    this.adoptDue()
                  }
                })
            }
            .width('100%')

            // 拆分建议
            if (this.suggestion.granularity !== null && this.suggestion.granularity.length > 0) {
              Column() {
                Text('拆分建议').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                Text(this.suggestion.granularity)
                  .fontSize(FontSize.body).fontColor(Color.textPrimary)
                  .lineHeight(20).margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }

            // 依据
            if (this.suggestion.reasons.length > 0) {
              Column() {
                Text('依据').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                ForEach(this.suggestion.reasons, (r: string, idx: number) => {
                  Text(`· ${r}`)
                    .fontSize(FontSize.body)
                    .fontColor(Color.textSecondary)
                    .lineHeight(20)
                    .width('100%')
                    .margin({ top: 2 })
                }, (r: string, idx: number) => `${idx}_${r}`)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, top: Space.sm })

        } else {
          Column() {
            Text('智能建议暂不可用')
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
              .onClick(() => { this.loadSuggestion() })
          }
          .width('100%')
          .padding({ left: Space.card, right: Space.card, bottom: Space.card })
        }
      }
    }
    .width('100%')
    .backgroundColor(this.suggestionCardBg())
    .borderRadius(Radius.card)
    .border({ width: 1, color: this.suggestionSource === 'fallback' ? Color.divider : Color.border })
  }

  build() {
    Column() {
      Text(this.isEdit ? '编辑任务' : '新建任务')
        .fontSize(FontSize.headline).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary)
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })

      Scroll() {
        Column({ space: Space.md }) {
          TextInput({ placeholder: '标题（必填）', text: this.title })
            .onChange((v: string) => {
              this.title = v
            })
            .height(44).backgroundColor(Color.surface).borderRadius(Radius.input)

          TextArea({ placeholder: '描述', text: this.desc })
            .onChange((v: string) => {
              this.desc = v
            })
            .height(100).backgroundColor(Color.surface).borderRadius(Radius.input)

          // 智能建议卡片：标题/描述有内容后出现，默认折叠
          if ((this.title.length > 0 || this.desc.length > 0) && !this.suggestionIgnored) {
            this.suggestionCard()
          }

          // 负责人（必填，只能一人）
          Row() {
            Text('负责人').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
            Text(this.ownerName()).fontSize(FontSize.body)
              .fontColor(this.ownerId === 0 ? Color.textTertiary : Color.textPrimary)
              .layoutWeight(1)
              .onClick(() => {
                this.showOwnerPicker = !this.showOwnerPicker
              })
          }
          .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

          if (this.showOwnerPicker) {
            Column() {
              ForEach(this.members, (m: MemberBrief) => {
                Row() {
                  Text(m.name).fontSize(FontSize.body)
                    .fontColor(this.ownerId === m.id ? Color.primary : Color.textPrimary)
                  Blank()
                  Text(m.dept !== null ? m.dept.name : '').fontSize(FontSize.caption).fontColor(Color.textTertiary)
                }
                .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  this.ownerId = m.id
                  this.showOwnerPicker = false
                })
              }, (m: MemberBrief) => `${m.id}`)
            }
            .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
          }

          // 所属课题（可空 = 独立任务）
          Row() {
            Text('所属课题').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
            Text(this.planName()).fontSize(FontSize.body)
              .fontColor(this.planId === 0 ? Color.textTertiary : Color.textPrimary)
              .layoutWeight(1)
              .onClick(() => {
                this.showPlanPicker = !this.showPlanPicker
              })
          }
          .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

          if (this.showPlanPicker) {
            Column() {
              Row() {
                Text('独立任务').fontSize(FontSize.body).fontColor(this.planId === 0 ? Color.primary : Color.textPrimary)
              }
              .width('100%').padding({ top: Space.sm, bottom: Space.sm })
              .onClick(() => {
                this.planId = 0
                this.showPlanPicker = false
              })
              ForEach(this.plansFlat, (p: PlanRef) => {
                Text(p.title).fontSize(FontSize.body)
                  .fontColor(this.planId === p.id ? Color.primary : Color.textPrimary)
                  .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                  .onClick(() => {
                    this.planId = p.id
                    this.showPlanPicker = false
                  })
              }, (p: PlanRef) => `${p.id}`)
            }
            .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
          }

          // 截止时间（可空 = 无截止组，点击弹日期选择器）
          Row() {
            Text('截止时间').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
            Text(this.dueAt.length > 0 ? this.dueAt : '点击选择日期')
              .fontSize(FontSize.body)
              .fontColor(this.dueAt.length > 0 ? Color.textPrimary : Color.textTertiary)
              .layoutWeight(1)
            if (this.dueAt.length > 0) {
              Text('清除').fontSize(FontSize.caption).fontColor(Color.primary)
                .padding({ left: Space.md })
                .onClick(() => {
                  this.dueAt = ''
                })
            }
          }
          .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)
          .onClick(() => {
            this.pickDueDate()
          })

          Button(this.isEdit ? '保存' : '提交')
            .width('100%').height(44).backgroundColor(Color.primary)
            .enabled(this.title.length > 0 && this.ownerId !== 0 && !this.submitting)
            .onClick(() => {
              this.submit()
            })
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(Color.canvas)
  }
}
