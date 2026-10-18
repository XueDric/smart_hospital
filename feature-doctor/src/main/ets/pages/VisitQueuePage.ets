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
  appointmentDisplayText
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { VisitItem, patientDisplayText } from '../model/DoctorModels';

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

  /*
   * 到院登记 / 转入候诊（2026-10-16 复核 D3 新增）。
   * 为什么必须有：服务端从改进 6 起把 `start` 收窄为只接受 waiting，
   * 而「谁确认到院」的答案是**医护侧确认**（患者自助签到本轮不做）。
   * 没有这两个动作，队列页上的单就永远停在 booked/arrived，接诊流程断在原地。
   */
  async arrive(item: VisitItem): Promise<void> {
    if (this.blockNotToday(item)) {
      return;
    }
    await this.act(async () => {
      await this.repository.arriveVisit(item.appointmentId);
      this.notice = '已登记到院';
      this.noticeTone = 'success';
    });
  }

  async waiting(item: VisitItem): Promise<void> {
    if (this.blockNotToday(item)) {
      return;
    }
    await this.act(async () => {
      await this.repository.waitingVisit(item.appointmentId);
      this.notice = '已转入候诊';
      this.noticeTone = 'success';
    });
  }

  async start(item: VisitItem): Promise<void> {
    if (this.blockNotToday(item)) {
      return;
    }
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
    // 把患者/就诊上下文一并带过去，省掉工作台首屏的空等：
    // `patient_id` 决定"既往病历"能不能马上就取，姓名/性别让患者栏首帧就能认人。
    // ⚠ 这些只是**省一次等待**，不是权威来源 —— 工作台仍会用 GET record 的
    //   `patient_id` / `patient_name` / `patient_gender` 校正。
    const params: Record<string, Object> = {
      'appointmentId': item.appointmentId,
      'seq': item.seqNo,
      'patientId': item.patientId,
      'patientName': item.patientName,
      'patientGender': item.patientGender,
      'visitDate': item.visitDate,
      'period': item.period
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

  /*
   * ⚠ 2026-10-16（复核 D3）：状态中文名**优先用服务端下发的 status_label**。
   *   本地 appointmentStatusText 只是兜底：中文名只该有一份权威实现（服务端
   *   `visitStatusLabel`），两边各写一份迟早会出现"服务端说已到院、客户端说候诊中"。
   *   —— 这个预言在 2026-10-16 晚的模拟器实测里应验了（7 个值漂了 4 个：
   *   booked/visiting/cancelled/no_show），现已把 `common-core` 的本地兜底逐字对齐服务端，
   *   并让 `feature-patient` 直接转调 `common-core`，不再有第二份词汇表。
   */
  private statusTextOf(item: VisitItem): string {
    // 「优先 status_label、本地兜底」的逻辑已收敛到 common-core 的 appointmentDisplayText，
    // 这里不再保留第二份实现（否则又是一个可能漂移的副本）。
    return appointmentDisplayText(item.status, item.statusLabel);
  }

  private clockText(epoch: number): string {
    if (epoch <= 0) {
      return '';
    }
    const at = new Date(epoch * 1000);
    const hh = at.getHours() < 10 ? `0${at.getHours()}` : `${at.getHours()}`;
    const mm = at.getMinutes() < 10 ? `0${at.getMinutes()}` : `${at.getMinutes()}`;
    return `${hh}:${mm}`;
  }

  /*
   * ★★ 2026-10-18 三端联调修（BUG-5）：接诊动作原本**不看就诊日**。
   *
   *   实测：预约的 `visit_date` 是 2026-12-24（当天是 2026-10-18），医生照样能
   *   「到院登记 → 转入候诊 → 开始接诊 → 完成就诊」，页面还显示「到院 18:51 ·
   *   候诊 0 分钟」—— 等于把两个月后的号当作今天在接诊，`arrived_at/started_at`
   *   于是被写成"今天"，时间线与事实不符，而且病历锁定后不可改。
   *
   *   为什么在客户端拦：服务端 `visit.arriveVisit/waitingVisit/startVisit`
   *   （`server/src/domain_emr.cj:1723/1733/1742`）只校验状态机，加日期硬门槛会
   *   连带影响 `server/tests` 里用固定日期夹具的验收用例（改动面大、风险高）；
   *   先把**界面上不可能点错**这件事做掉，服务端硬门槛记进文档 §9 待办。
   *   ⚠ 这是"防误操作"，不是安全边界 —— 直接调 API 仍能绕过。
   */
  private isToday(dateText: string): boolean {
    const now = new Date();
    const mm = now.getMonth() + 1;
    const dd = now.getDate();
    const month = mm < 10 ? `0${mm}` : `${mm}`;
    const day = dd < 10 ? `0${dd}` : `${dd}`;
    return dateText === `${now.getFullYear()}-${month}-${day}`;
  }

  private blockNotToday(item: VisitItem): boolean {
    if (this.isToday(item.visitDate)) {
      return false;
    }
    this.notice = `该号的就诊日是 ${item.visitDate}，不是今天，不能到院登记/接诊`;
    this.noticeTone = 'error';
    return true;
  }

  private waitText(item: VisitItem): string {
    // 候诊时长 = arrived_at → started_at（还没接诊就用"现在"算，让医生知道等了多久）
    if (item.arrivedAt <= 0) {
      return '';
    }
    const nowSec = Math.floor(Date.now() / 1000);
    const to = item.startedAt > 0 ? item.startedAt : nowSec;
    const mins = Math.floor((to - item.arrivedAt) / 60);
    if (mins < 0) {
      return '';
    }
    if (mins < 60) {
      return `候诊 ${mins} 分钟`;
    }
    return `候诊 ${Math.floor(mins / 60)} 小时 ${mins % 60} 分钟`;
  }

  /*
   * 时间线文本：把服务端给的三时间戳读出来（0 = 这一步还没发生）。
   * 为什么值得显示：`arrived_at` 是"患者到了但没人管"的唯一证据，
   * 队列页看不到它时，"等了 40 分钟"这种事只能靠患者投诉才知道。
   */
  private timelineText(item: VisitItem): string {
    const parts: string[] = [];
    if (item.arrivedAt > 0) {
      parts.push(`到院 ${this.clockText(item.arrivedAt)}`);
    }
    if (item.startedAt > 0) {
      parts.push(`接诊 ${this.clockText(item.startedAt)}`);
    }
    if (item.finishedAt > 0) {
      parts.push(`完成 ${this.clockText(item.finishedAt)}`);
    }
    if (item.arrivedAt > 0 && item.finishedAt <= 0) {
      const wait = this.waitText(item);
      if (wait.length > 0) {
        parts.push(wait);
      }
    }
    return parts.join(' · ');
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
      await SessionStore.clearLogin();
      AppRouter.getInstance().reset(RouteName.DOCTOR_LOGIN);
    } catch (error) {
      // 网络注销未确认：本地身份照常清除（设备安全优先），但如实提示，
      // 不宣称服务端已注销。下次任何鉴权请求会 401 并被送回登录页。
      await SessionStore.clearLogin();
      this.notice = '服务端注销未确认（网络异常），本地登录已清除';
      this.noticeTone = 'error';
      this.loggingOut = false;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: `接诊队列（${SessionStore.getDisplayName()}）`,
        /*
         * ★★ 2026-10-18 三端联调修：副标题原写「按状态展示今日接诊顺序」，
         *   但下面的分段第一格是 `ALL`（只按**时段**过滤，不按日期），而服务端
         *   `GET /api/v1/doctor/visits` 没有日期参数、返回该医生**全部**预约 ——
         *   实测 2026-12-24 的单子出现在"今日"里。这里把口径改成如实描述。
         */
        subtitle: '按状态展示接诊顺序（含历史与未来日期）'
      })

      Row() {
        /*
         * ★ 同上：原来第一格叫「今日」，而它实际是"全部时段"。改名为「全部」，
         *   不再暗示日期过滤 —— 卡片上各自带 `visit_date`，日期不会被藏掉。
         */
        this.segment('ALL', '全部')
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
                    Text(`序号 ${item.seqNo} · ${patientDisplayText(item.patientId, item.patientName,
                      item.patientGender)}`)
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
                    text: this.statusTextOf(item),
                    color: appointmentStatusColor(item.status),
                    chipBackground: this.chipBackground(item.status)
                  })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                if (this.timelineText(item).length > 0) {
                  Text(this.timelineText(item))
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .margin({ top: 6 })
                }

                Row() {
                  Text(`${item.visitDate} ${item.period}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .layoutWeight(1)

                  /*
                   * ⚠ 2026-10-16（复核 D3）：服务端的流转矩阵是
                   *   booked → arrived → waiting → visiting → done（+ 各阶段可 no_show）。
                   *   上一版这里只在 `booked` 时渲染「开始接诊」—— 按下去必然 409
                   *   VISIT_BAD_STATE；而 arrived/waiting 的单**一个可点的按钮都没有**，
                   *   医生既接不了诊、也完不成就诊。医生端主流程整个不可用。
                   *   现在按状态给该状态的下一步（按钮名与服务端动作同名，避免二次翻译）。
                   */
                  if (item.status === 'booked') {
                    Button('爽约')
                      .height(AppSize.TOUCH_MIN)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.DANGER)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: AppColor.DANGER })
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.noShow(item))
                    Button('到院登记')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.arrive(item))
                  } else if (item.status === 'arrived') {
                    Button('爽约')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.DANGER)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: AppColor.DANGER })
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.noShow(item))
                    Button('转入候诊')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.waiting(item))
                  } else if (item.status === 'waiting') {
                    Button('爽约')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.DANGER)
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: AppColor.DANGER })
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.noShow(item))
                    Button('开始接诊')
                      .height(AppSize.TOUCH_MIN)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.start(item))
                  } else if (item.status === 'visiting') {
                    Button('写病历')
                      .height(AppSize.TOUCH_MIN)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.writeRecord(item))
                    Button('完成就诊')
                      .height(AppSize.TOUCH_MIN)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.finish(item))
                  } else if (item.status === 'done') {
                    /*
                     * 已完成的单也要能进病历页 —— 此前这条分支不存在，医生一旦点了
                     * 「完成就诊」就再也回不到那份病历（只能重开 App 从别处找），
                     * 而改进 3 的「版本历史」入口恰恰在病历页里（只读展示锁定后的文书）。
                     */
                    Button('看病历')
                      .height(AppSize.TOUCH_MIN)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.writeRecord(item))
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
      .height(AppSize.TOUCH_MIN)
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
