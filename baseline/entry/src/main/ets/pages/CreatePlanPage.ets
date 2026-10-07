/**
 * 作者：刘运泽
 * 功能：新建/编辑课题页（POST / PATCH，client_token 防重）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  截止时间改为日期+时间选择器
 *   2026-09-17  编辑与移动 + 日历对账接线
 *   2026-09-17  恢复设计稿外观
 */
// 新建课题 / 子课题。顶层课题必填部门，子课题必填父课题（不存部门，继承根课题）。
// 创建走 POST /plans，带 client_token 防重复提交。

import router from '@ohos.router'
import { PlanApi, CreatePlanRequest, UpdatePlanRequest } from '../api/PlanApi'
import { MemberApi } from '../api/MemberApi'
import { DeptApi, DeptView } from '../api/DeptApi'
import { MemberBrief } from '../api/AuthApi'
import { PlanRef } from '../api/TaskApi'
import { flattenPlans } from '../util/PlanTree'
import { genClientToken } from '../util/ClientToken'
import { formatYmdHm } from '../util/DateFmt'
import { Color, FontSize, Radius, Space } from '../core/Theme'

interface CreatePlanParams {
  plan_id?: number
  parent_id?: number
}

@Entry
@Component
struct CreatePlanPage {
  @State isEdit: boolean = false
  @State editingId: number = 0
  @State title: string = ''
  @State desc: string = ''
  @State isTopLevel: boolean = true
  @State ownerId: number = 0
  @State deptId: number = 0
  @State parentId: number = 0
  @State dueAt: string = ''
  @State showOwnerPicker: boolean = false
  @State showDeptPicker: boolean = false
  @State showParentPicker: boolean = false
  @State members: MemberBrief[] = []
  @State depts: DeptView[] = []
  @State plansFlat: PlanRef[] = []
  @State submitting: boolean = false

  private planApi: PlanApi = new PlanApi()
  private memberApi: MemberApi = new MemberApi()
  private deptApi: DeptApi = new DeptApi()

  aboutToAppear(): void {
    this.loadOptions()
    const p = router.getParams() as CreatePlanParams
    if (p !== undefined && p !== null && p.plan_id !== undefined && p.plan_id > 0) {
      this.isEdit = true
      this.editingId = p.plan_id
      this.loadDetail(p.plan_id)
    } else if (p !== undefined && p !== null && p.parent_id !== undefined && p.parent_id > 0) {
      // 从课题详情「新建子课题」进入：预选子课题 + 父课题
      this.isTopLevel = false
      this.parentId = p.parent_id
    }
  }

  private async loadOptions(): Promise<void> {
    const membersResp = await this.memberApi.list()
    if (membersResp.ok && membersResp.data) {
      this.members = membersResp.data.items
    }
    const deptsResp = await this.deptApi.list()
    if (deptsResp.ok && deptsResp.data) {
      this.depts = deptsResp.data.items
    }
    const plansResp = await this.planApi.list()
    if (plansResp.ok && plansResp.data) {
      this.plansFlat = flattenPlans(plansResp.data.items)
    }
  }

  private async loadDetail(planId: number): Promise<void> {
    const resp = await this.planApi.detail(planId)
    if (resp.ok && resp.data) {
      const plan = resp.data.plan
      this.title = plan.title
      this.desc = plan.desc
      this.ownerId = plan.owner !== null ? plan.owner.id : 0
      this.dueAt = plan.due_at !== null ? plan.due_at : ''
      this.isTopLevel = plan.parent_id === 0
      if (plan.parent_id === 0) {
        this.deptId = plan.dept !== null ? plan.dept.id : 0
      } else {
        this.parentId = plan.parent_id
      }
    } else {
      AlertDialog.show({
        title: '加载失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      })
    }
  }

  private ownerName(): string {
    for (const m of this.members) {
      if (m.id === this.ownerId) return m.name
    }
    return '请选择'
  }

  private deptName(): string {
    for (const d of this.depts) {
      if (d.id === this.deptId) return d.name
    }
    return '请选择'
  }

  private parentName(): string {
    for (const p of this.plansFlat) {
      if (p.id === this.parentId) return p.title
    }
    return '请选择'
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
    let respOk = false
    let errMsg = '请重试'
    if (this.isEdit) {
      // 编辑：PATCH /plans/{id}。部门 / 父级不能改（后端禁止），改父级走 move 接口。
      const data: UpdatePlanRequest = {
        title: this.title,
        desc: this.desc,
        owner_id: this.ownerId,
        due_at: this.dueAt.length > 0 ? this.dueAt : null
      }
      const resp = await this.planApi.update(this.editingId, data)
      respOk = resp.ok && resp.data !== undefined
      errMsg = resp.error?.message ?? '请重试'
    } else {
      const data: CreatePlanRequest = {
        title: this.title,
        owner_id: this.ownerId,
        client_token: genClientToken()
      }
      if (this.desc.length > 0) data.desc = this.desc
      if (this.dueAt.length > 0) data.due_at = this.dueAt
      if (this.isTopLevel) {
        data.dept_id = this.deptId
      } else {
        data.parent_id = this.parentId
      }
      const resp = await this.planApi.create(data)
      respOk = resp.ok && resp.data !== undefined
      errMsg = resp.error?.message ?? '请重试'
    }
    this.submitting = false
    if (respOk) {
      router.back()
    } else {
      AlertDialog.show({
        title: this.isEdit ? '保存失败' : '创建失败',
        message: errMsg,
        primaryButton: { value: '知道了', action: () => {} }
      })
    }
  }

  build() {
    Column() {
      Text(this.isEdit ? '编辑课题' : '新建课题')
        .fontSize(FontSize.headline).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary)
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })

      Scroll() {
        Column({ space: Space.md }) {
          if (!this.isEdit) {
            Row({ space: Space.sm }) {
              Text('顶层课题')
                .fontSize(FontSize.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isTopLevel ? Color.surface : Color.textSecondary)
                .backgroundColor(this.isTopLevel ? Color.primary : Color.primarySoft)
                .borderRadius(Radius.button)
                .padding({ left: Space.lg, right: Space.lg, top: 9, bottom: 9 })
                .onClick(() => {
                  this.isTopLevel = true
                  this.parentId = 0
                })
              Text('子课题')
                .fontSize(FontSize.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isTopLevel ? Color.textSecondary : Color.surface)
                .backgroundColor(this.isTopLevel ? Color.primarySoft : Color.primary)
                .borderRadius(Radius.button)
                .padding({ left: Space.lg, right: Space.lg, top: 9, bottom: 9 })
                .onClick(() => {
                  this.isTopLevel = false
                  this.deptId = 0
                })
            }
            .width('100%')
          }

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

          // 负责人（必填，任意层级课题都要有人负责）
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

          if (!this.isEdit && this.isTopLevel) {
            // 顶层课题：部门（必填）
            Row() {
              Text('部门').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
              Text(this.deptName()).fontSize(FontSize.body)
                .fontColor(this.deptId === 0 ? Color.textTertiary : Color.textPrimary)
                .layoutWeight(1)
                .onClick(() => {
                  this.showDeptPicker = !this.showDeptPicker
                })
            }
            .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

            if (this.showDeptPicker) {
              Column() {
                ForEach(this.depts, (d: DeptView) => {
                  Text(d.name).fontSize(FontSize.body)
                    .fontColor(this.deptId === d.id ? Color.primary : Color.textPrimary)
                    .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                    .onClick(() => {
                      this.deptId = d.id
                      this.showDeptPicker = false
                    })
                }, (d: DeptView) => `${d.id}`)
              }
              .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
            }
          } else if (!this.isEdit) {
            // 子课题：父课题（必填）
            Row() {
              Text('父课题').fontSize(FontSize.body).fontColor(Color.textPrimary).width(72)
              Text(this.parentName()).fontSize(FontSize.body)
                .fontColor(this.parentId === 0 ? Color.textTertiary : Color.textPrimary)
                .layoutWeight(1)
                .onClick(() => {
                  this.showParentPicker = !this.showParentPicker
                })
            }
            .width('100%').padding(Space.card).backgroundColor(Color.surface).borderRadius(Radius.card)

            if (this.showParentPicker) {
              Column() {
                ForEach(this.plansFlat, (p: PlanRef) => {
                  Text(p.title).fontSize(FontSize.body)
                    .fontColor(this.parentId === p.id ? Color.primary : Color.textPrimary)
                    .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                    .onClick(() => {
                      this.parentId = p.id
                      this.showParentPicker = false
                    })
                }, (p: PlanRef) => `${p.id}`)
              }
              .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
            }
          }

          // 截止时间（可空，点击弹日期选择器）
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
            .enabled(this.title.length > 0 && this.ownerId !== 0 && (this.isEdit || (this.isTopLevel ? this.deptId !== 0 : this.parentId !== 0)) && !this.submitting)
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
