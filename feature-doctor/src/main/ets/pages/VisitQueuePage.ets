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
  RouteName,
  SessionStore,
  StatusChip,
  appointmentStatusColor,
  appointmentStatusText
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { VisitItem } from '../model/DoctorModels';

@ComponentV2
export struct VisitQueuePage {
  private readonly repository: DoctorRepository = DoctorRepository.getInstance();
  @Local visits: VisitItem[] = [];
  @Local loading: boolean = true;
  @Local filter: string = 'ALL';
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local loggingOut: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.visits = await this.repository.visits();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  async start(item: VisitItem): Promise<void> {
    await this.act(async () => {
      await this.repository.startVisit(item.appointmentId);
      this.notice = '已开始接诊';
      this.noticeTone = 'success';
    });
  }

  async noShow(item: VisitItem): Promise<void> {
    await this.act(async () => {
      await this.repository.noShow(item.appointmentId);
      this.notice = '已标记爽约';
      this.noticeTone = 'success';
    });
  }

  async finish(item: VisitItem): Promise<void> {
    await this.act(async () => {
      await this.repository.finishVisit(item.appointmentId);
      this.notice = '就诊已完成';
      this.noticeTone = 'success';
    });
  }

  private async act(action: () => Promise<void>): Promise<void> {
    this.notice = '';
    try {
      await action();
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  private writeRecord(item: VisitItem): void {
    const params: Record<string, Object> = {
      'appointmentId': item.appointmentId,
      'seq': item.seqNo
    };
    AppRouter.getInstance().push(RouteName.DOCTOR_RECORD, params);
  }

  private recordProgress(item: VisitItem): string {
    if (item.recordStatus === 'locked') {
      return `已填 ${item.recordFilled}/7 · 已锁定`;
    }
    if (item.recordStatus === 'draft') {
      return `已填 ${item.recordFilled}/7 · 草稿`;
    }
    return '无病历（record_status: none）';
  }

  private filtered(): VisitItem[] {
    if (this.filter === 'ALL') {
      return this.visits;
    }
    const result: VisitItem[] = [];
    for (const item of this.visits) {
      if (item.period === this.filter) {
        result.push(item);
      }
    }
    return result;
  }

  private async logout(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    this.loggingOut = true;
    this.notice = '';
    try {
      await this.repository.logout();
      SessionStore.clearLogin();
      AppRouter.getInstance().reset(RouteName.DOCTOR_LOGIN);
    } catch (error) {
      // 网络注销未确认：本地身份照常清除（设备安全优先），但如实提示，
      // 不宣称服务端已注销。下次任何鉴权请求会 401 并被送回登录页。
      SessionStore.clearLogin();
      this.notice = '服务端注销未确认（网络异常），本地登录已清除';
      this.noticeTone = 'error';
      this.loggingOut = false;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: `接诊队列（${SessionStore.getDisplayName()}）`,
        subtitle: '队列仅显示序号与患者编号，不显示姓名'
      })

      Row() {
        this.segment('ALL', '今日')
        this.segment('AM', '上午')
        this.segment('PM', '下午')
      }
      .width('100%')
      .padding(3)
      .backgroundColor(AppColor.SURFACE_ALT)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .margin({ top: AppSize.GAP, bottom: AppSize.GAP })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ bottom: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (this.filtered().length === 0) {
            EmptyState({ title: '该时段暂无就诊安排' })
          } else {
            ForEach(this.filtered(), (item: VisitItem) => {
              Column() {
                Row() {
                  Column() {
                    Text(`序号 ${item.seqNo} · 患者 #${item.patientId}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(this.recordProgress(item))
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 6 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (item.previsitReady) {
                    Text('预问诊')
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.INFO)
                      .backgroundColor(AppColor.INFO_SOFT)
                      .borderRadius(6)
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .margin({ right: AppSize.GAP })
                  }

                  StatusChip({
                    text: appointmentStatusText(item.status),
                    color: appointmentStatusColor(item.status),
                    chipBackground: this.chipBackground(item.status)
                  })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Row() {
                  Text(`${item.visitDate} ${item.period}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .layoutWeight(1)

                  if (item.status === 'booked') {
                    Button('爽约')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.DANGER)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: AppColor.DANGER })
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.noShow(item))
                    Button('开始接诊')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.start(item))
                  } else if (item.status === 'visiting') {
                    Button('写病历')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.writeRecord(item))
                    Button('完成就诊')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.finish(item))
                  }
                }
                .width('100%')
                .margin({ top: AppSize.GAP })
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .opacity(item.status === 'done' || item.status === 'no_show' ? 0.6 : 1)
              .margin({ bottom: AppSize.GAP })
            }, (item: VisitItem) => `${item.appointmentId}-${item.status}-${item.recordStatus}`)
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.PAGE_PADDING })
      }
      .layoutWeight(1)
      .width('100%')

      Button('退出登录')
        .width('100%')
        .height(AppSize.CONTROL_HEIGHT)
        .fontSize(AppText.BODY)
        .fontColor(AppColor.TEXT_SECONDARY)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: AppColor.BORDER })
        .borderRadius(AppSize.CONTROL_RADIUS)
        .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 16 })
        .onClick(() => this.logout())
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 })
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  segment(value: string, label: string) {
    Button(label)
      .layoutWeight(1)
      .height(40)
      .fontSize(AppText.CAPTION)
      .fontColor(this.filter === value ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
      .backgroundColor(this.filter === value ? AppColor.PRIMARY_SOFT : Color.Transparent)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .onClick(() => {
        this.filter = value;
      })
  }

  private chipBackground(status: string): string {
    if (status === 'done') {
      return AppColor.SUCCESS_SOFT;
    }
    if (status === 'cancelled' || status === 'no_show') {
      return AppColor.DANGER_SOFT;
    }
    if (status === 'visiting') {
      return AppColor.PRIMARY_SOFT;
    }
    return AppColor.INFO_SOFT;
  }
}
