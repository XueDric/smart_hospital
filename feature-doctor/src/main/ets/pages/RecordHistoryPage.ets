import {
  ApiError,
  AppColor,
  AppRouter,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  PageHeader,
  asNumber,
  formatEpoch
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { EmrSection, RevisionDetail, RevisionDiff, RevisionDiffSection, RevisionItem } from '../model/DoctorModels';

/*
 * 病历修订历史（改进 3）—— **医生端只读**。
 *
 * 三个事实决定了这一页的形状，写在最前面免得后来人"顺手加功能"：
 *  1. 版本是**稀疏**的：只有 `lock` 与 `reopen` 会落版本，保存草稿（PUT）不落。
 *     所以"v2 和 v3 之间医生改了十次"是正常的，界面不能暗示"每一版=一次保存"。
 *  2. 解锁重写（reopen）是**管理员专属**，医生调它一律 403 FORBIDDEN_ROLE。
 *     这一页因此没有任何"解锁"入口 —— 它能做的只有看。
 *  3. 取不到的版本是 404 REVISION_NOT_FOUND，**不是空对象**：绝不能把"取不到"
 *     渲染成"七段全空的版本"，那看起来像病历被人清空了。
 */
@ComponentV2
export struct RecordHistoryPage {
  private readonly repository: DoctorRepository = DoctorRepository.getInstance();

  @Local appointmentId: number = 0;
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  // 列表按**最新在前**展示：服务端固定升序（v1 在前），反转是展示层的决定，不属于契约。
  @Local items: RevisionItem[] = [];
  /*
   * 0 = 停在列表；>0 = 正在看该版。
   * 详情与逐段对比都在这一层里切，**不再开新路由** —— 详情本来只是数据，
   * 多开一层就多一次"返回时参数还在不在"的隐患（AppRouter 的栈就是为了这个才改成存参数的）。
   */
  @Local selectedVersion: number = 0;
  @Local detail: RevisionDetail = new RevisionDetail();
  @Local hasDetail: boolean = false;
  @Local busy: boolean = false;
  @Local diff: RevisionDiff = new RevisionDiff();
  @Local hasDiff: boolean = false;

  aboutToAppear(): void {
    this.appointmentId = asNumber(AppRouter.getInstance().getParams()['appointmentId']);
    if (this.appointmentId <= 0) {
      this.loading = false;
      this.notice = '缺少挂号单编号，无法读取版本历史';
      this.noticeTone = 'error';
      return;
    }
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      const ascending = await this.repository.getRevisions(this.appointmentId);
      const newestFirst: RevisionItem[] = [];
      for (let i = ascending.length - 1; i >= 0; i--) {
        newestFirst.push(ascending[i]);
      }
      this.items = newestFirst;
    } catch (error) {
      // 404 APPOINTMENT_NOT_FOUND 也会走到这里：那不是"你看不了"，是"这单不归你"。
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  async openDetail(version: number): Promise<void> {
    this.selectedVersion = version;
    this.hasDetail = false;
    this.hasDiff = false;
    this.diff = new RevisionDiff();
    this.busy = true;
    this.notice = '';
    try {
      this.detail = await this.repository.getRevision(this.appointmentId, version);
      this.hasDetail = true;
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.busy = false;
    }
  }

  /*
   * 与上一版逐段对比。
   * ⚠ 刻意**不**自己算 `against = version - 1`：让服务端定义"上一版"是谁，
   *   客户端只显示它回话里的 left/right 版本号（那才是权威的"跟谁比"）。
   *   也正因如此，v1 没有上一版 —— 服务端对"v1 不给 against"直接 400（它拒绝退化成
   *   "拿 v1 跟自己比"），所以这里在 v1 上连按钮都不给。
   */
  async loadDiff(): Promise<void> {
    if (this.selectedVersion <= 1) {
      return;
    }
    this.busy = true;
    this.notice = '';
    try {
      this.diff = await this.repository.getRevisionDiff(this.appointmentId, this.selectedVersion);
      this.hasDiff = true;
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.busy = false;
    }
  }

  // 列表里的「与 vN 对比」：先把该版读出来（对比面板要显示它的全文），再取 diff。
  // 单独开一个方法而不是在 onClick 里写 async 箭头函数 —— 本仓库的按钮一律是
  // `onClick(() => this.xxx())`，异步回调没有先例，不去当第一个。
  async openDiff(version: number): Promise<void> {
    await this.openDetail(version);
    if (this.hasDetail) {
      await this.loadDiff();
    }
  }

  private closeDetail(): void {    this.selectedVersion = 0;
    this.hasDetail = false;
    this.hasDiff = false;
    this.diff = new RevisionDiff();
    this.notice = '';
  }

  // 返回键先退"层"再退"页"：在详情里按返回应该回列表，而不是直接离开本页。
  private goBack(): void {
    if (this.selectedVersion > 0) {
      this.closeDetail();
      return;
    }
    AppRouter.getInstance().back();
  }

  // ── 展示用中文名（只影响措辞，不参与任何判定） ────────────────────────────

  private operationText(item: RevisionItem): string {
    if (item.operation === 'reopen') {
      // reopen 必须带理由（4–255 字）；理由就是这一版存在的意义，直接展示。
      return item.reason.length > 0 ? `管理员解锁重写 · ${item.reason}` : '管理员解锁重写';
    }
    if (item.operation === 'lock') {
      return '医生定稿锁定';
    }
    return item.operation;
  }

  /*
   * `operator_role` 可能是**空串** = 未知（存量病历由 migrateSchema 补写的那一版没有角色），
   * 不是"没有权限"。渲染成空白会让人以为数据坏了，所以要显式说成「系统补录」。
   */
  private operatorText(item: RevisionItem): string {
    const owner = item.operatorUserId > 0 ? ` · user #${item.operatorUserId}` : '';
    if (item.operatorRole.length === 0) {
      return `操作者未知（系统补录）${owner}`;
    }
    if (item.operatorRole === 'admin') {
      return `管理员${owner}`;
    }
    if (item.operatorRole === 'doctor') {
      return `医生${owner}`;
    }
    return `${item.operatorRole}${owner}`;
  }

  private statusText(status: string): string {
    if (status === 'locked') {
      return '已定稿';
    }
    if (status === 'draft') {
      return '草稿';
    }
    return status;
  }

  private diffHeadline(): string {
    // 段数用服务端给的 `changed_count`（**不**自己去数 changed 的段 —— 那是重算，
    // 而且"状态变了但七段一字未改"这种版本会让两个数对不上）。
    const parts: string[] = [`服务端判定 ${this.diff.changedCount} 段有变化`];
    if (this.diff.statusChanged) {
      parts.push('病历状态也变了（如 草稿 → 已定稿）');
    }
    return parts.join('，');
  }

  private unchangedLabels(): string {
    const labels: string[] = [];
    for (const section of this.diff.sections) {
      if (!section.changed) {
        labels.push(section.label);
      }
    }
    return labels.join('、');
  }

  private sectionValueText(value: string): string {
    return value.length > 0 ? value : '（未填写）';
  }

  build() {
    Column() {
      PageHeader({
        title: this.selectedVersion > 0 ? `修订 v${this.selectedVersion}` : '病历版本历史',
        subtitle: `挂号单 #${this.appointmentId} · 只读`,
        showBack: true,
        interceptBack: true,
        onBack: () => this.goBack()
      })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      if (this.loading) {
        LoadingBlock()
      } else if (this.selectedVersion > 0) {
        this.detailView()
      } else if (this.items.length === 0) {
        EmptyState({
          title: '还没有任何修订版本',
          description: '版本只在定稿锁定与管理员解锁重写时产生；只保存草稿不会落版本'
        })
      } else {
        this.listView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  listView() {
    List() {
      ListItem() {
        Text('版本只在「定稿锁定」与「管理员解锁重写」时产生；保存草稿不会落版本，' +
          '所以相邻两版之间医生可能已改过多次。')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .padding({ bottom: AppSize.GAP })
      }

      ForEach(this.items, (item: RevisionItem) => {
        ListItem() {
          Column() {
            Row() {
              Text(`v${item.version}`)
                .fontSize(AppText.HEADING)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.PRIMARY)
              Text(this.statusText(item.status))
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
                .margin({ left: AppSize.GAP })
              Blank()
              Text(formatEpoch(item.createdAt))
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(this.operationText(item))
              .fontSize(AppText.BODY)
              .fontColor(AppColor.TEXT)
              .width('100%')
              .margin({ top: 6 })

            Text(this.operatorText(item))
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 4 })

            Row() {
              Button('看这一版')
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.PRIMARY)
                .backgroundColor(AppColor.PRIMARY_SOFT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .enabled(!this.busy)
                .onClick(() => this.openDetail(item.version))

              // v1 没有上一版 → 不给对比入口（服务端那边是 400，不是"返回空对比"）。
              if (item.version > 1) {
                Button(`与 v${item.version - 1} 对比`)
                  .height(AppSize.TOUCH_MIN)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.PRIMARY)
                  .backgroundColor(AppColor.PRIMARY_SOFT)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .margin({ left: AppSize.GAP })
                  .enabled(!this.busy)
                  .onClick(() => this.openDiff(item.version))
              } else {
                Text('第一版，无上一版可对比')
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ left: AppSize.GAP })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: AppSize.GAP })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ bottom: AppSize.GAP })
        }
      }, (item: RevisionItem) => `rev-${item.version}`)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
  }

  @Builder
  detailView() {
    if (this.hasDiff) {
      this.diffBody()
    } else {
      this.detailBody()
    }
  }

  @Builder
  detailBody() {
    Column() {
      if (this.busy) {
        LoadingBlock({ text: '正在读取该版本' })
      } else if (!this.hasDetail) {
        // 取不到就是 404 REVISION_NOT_FOUND（已在上方横幅提示），**不留白屏**，
        // 更不能渲染成"七段全空的一版"。
        EmptyState({ title: '这一版读取失败', description: '返回列表重试，或换一版查看' })
      } else {
        Scroll() {
          Column() {
            Text(this.operationText(this.detail))
              .fontSize(AppText.SUBHEADING)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.TEXT)
              .width('100%')
            Text(`${this.statusText(this.detail.status)} · ${this.operatorText(this.detail)}` +
              ` · ${formatEpoch(this.detail.createdAt)}`)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 6 })

            ForEach(this.detail.sections, (section: EmrSection) => {
              Column() {
                Text(section.label)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .width('100%')
                Text(this.sectionValueText(section.value))
                  .fontSize(AppText.BODY)
                  .fontColor(section.value.length > 0 ? AppColor.TEXT : AppColor.DISABLED)
                  .width('100%')
                  .margin({ top: 4 })
              }
              .width('100%')
              .padding({ top: AppSize.GAP, bottom: AppSize.GAP })
              .border({ width: { bottom: 1 }, color: AppColor.BORDER })
            }, (section: EmrSection) => `d-${section.key}`)

            if (this.selectedVersion > 1) {
              Button(`与 v${this.selectedVersion - 1} 对比`)
                .width('100%')
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .fontColor(AppColor.PRIMARY)
                .backgroundColor(AppColor.PRIMARY_SOFT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .enabled(!this.busy)
                .margin({ top: AppSize.SECTION_GAP })
                .onClick(() => this.loadDiff())
            } else {
              InfoBanner({ message: '这是第一版，没有上一版可对比', tone: 'info' })
                .margin({ top: AppSize.SECTION_GAP })
            }

            // 版本详情里的段是**快照**，不可编辑 —— 这页只读是设计，不是没做完。
            Text('修订版本是只读快照，不提供编辑与解锁入口（解锁重写是管理员动作）')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: AppSize.GAP, bottom: 24 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
  }

  @Builder
  diffBody() {
    Column() {
      Scroll() {
        Column() {
          Text(`v${this.diff.left.version} → v${this.diff.right.version}`)
            .fontSize(AppText.HEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
            .width('100%')
          Text(this.diffHeadline())
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6 })

          ForEach(this.diff.sections, (section: RevisionDiffSection) => {
            if (section.changed) {
              Column() {
                Row() {
                  Text(section.label)
                    .fontSize(AppText.SUBHEADING)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  Text('有变化')
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.WARNING)
                    .backgroundColor(AppColor.WARNING_SOFT)
                    .borderRadius(AppSize.CONTROL_RADIUS)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Text(`旧（v${this.diff.left.version}）`)
                  .fontSize(AppText.MICRO)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .width('100%')
                  .margin({ top: 8 })
                Text(this.sectionValueText(section.left))
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .width('100%')

                Text(`新（v${this.diff.right.version}）`)
                  .fontSize(AppText.MICRO)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .width('100%')
                  .margin({ top: 8 })
                Text(this.sectionValueText(section.right))
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.TEXT)
                  .width('100%')
              }
              .width('100%')
              .padding({ top: AppSize.GAP, bottom: AppSize.GAP })
              .border({ width: { bottom: 1 }, color: AppColor.BORDER })
            }
          }, (section: RevisionDiffSection) => `diff-${section.key}`)

          if (this.unchangedLabels().length > 0) {
            Text(`未变化的段：${this.unchangedLabels()}`)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: AppSize.GAP })
          }

          Button(`看 v${this.diff.right.version} 全文`)
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.PRIMARY)
            .backgroundColor(AppColor.PRIMARY_SOFT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.SECTION_GAP, bottom: 24 })
            .onClick(() => {
              this.hasDiff = false;
            })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
  }
}
