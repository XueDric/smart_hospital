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
  asNumber,
  formatEpoch
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { EmrRecord, EmrSection, PrevisitSlot, PrevisitSummary } from '../model/DoctorModels';

@ComponentV2
export struct EmrEditPage {
  private readonly repository: DoctorRepository = DoctorRepository.getInstance();
  @Local appointmentId: number = 0;
  @Local seq: number = 0;
  @Local sections: EmrSection[] = [];
  @Local values: string[] = [];
  @Local locked: boolean = false;
  @Local loading: boolean = true;
  @Local saving: boolean = false;
  // 页面是否有未保存的输入改动；用于「提交锁定前先保存」与状态栏提示。
  @Local dirty: boolean = false;
  // 服务端按内容快照做乐观锁，返回 409 EMR_CHANGED 时置位；保留医生输入，提示核对。
  @Local conflicted: boolean = false;
  // 已确认保存的版本（记录 updated_at，秒）；用于状态栏「已保存」展示。
  @Local recordUpdatedAt: number = 0;
  // 患者预问诊摘要（来自服务端 5.28.1，取代本机 SessionStore 盲预填）。
  @Local previsit: PrevisitSummary = new PrevisitSummary();
  @Local hasPrevisitSummary: boolean = false;
  // 病历里由预问诊预填的段 key（previsit_ref.sections），用于段角标。
  @Local previsitRefSections: string[] = [];
  @Local notice: string = '';
  @Local noticeTone: string = 'info';

  aboutToAppear(): void {
    const params = AppRouter.getInstance().getParams();
    this.appointmentId = asNumber(params['appointmentId']);
    this.seq = asNumber(params['seq']);
    this.load();
    this.loadPrevisit();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      const record = await this.repository.getRecord(this.appointmentId);
      this.applyRecord(record);
      this.dirty = false;
      this.conflicted = false;
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  // 用服务端返回的记录刷新页面，并记录已确认的 updated_at（乐观锁基准）。
  private applyRecord(record: EmrRecord): void {
    this.sections = record.sections;
    this.values = [];
    for (const section of record.sections) {
      this.values.push(section.value);
    }
    this.locked = record.locked;
    this.recordUpdatedAt = record.updatedAt;
    this.previsitRefSections = record.previsitRefSections;
  }

  // 预问诊摘要只在进页时取一次：没有摘要（PREVISIT_NOT_FOUND）是正常态，静默。
  async loadPrevisit(): Promise<void> {
    try {
      this.previsit = await this.repository.getPrevisit(this.appointmentId);
      this.hasPrevisitSummary = true;
    } catch (error) {
      // 无论「无摘要」还是网络/鉴权失败，都不打断病历页；没有卡片可显示即可。
      this.hasPrevisitSummary = false;
    }
  }

  // 统一错误出口：EMR_CHANGED 视为冲突，保留本地输入并提示核对，绝不自动采用最新版本。
  private handleError(error: Error): void {
    const apiError = ApiError.from(error);
    if (apiError.code === 'EMR_CHANGED') {
      this.conflicted = true;
      this.notice = '病历已被其他端修改，已保留你的输入，请核对最新内容后再保存';
      this.noticeTone = 'error';
      return;
    }
    this.notice = apiError.userMessage();
    this.noticeTone = 'error';
  }

  private valuesMap(): Record<string, string> {
    const result: Record<string, string> = {};
    for (let i = 0; i < this.sections.length; i++) {
      result[this.sections[i].key] = this.values[i] ?? '';
    }
    return result;
  }

  private statusText(): string {
    if (this.loading) {
      return '加载中…';
    }
    if (this.conflicted) {
      return '存在冲突：已保留你的输入，请核对最新内容';
    }
    if (this.dirty) {
      return '未保存改动';
    }
    if (this.recordUpdatedAt > 0) {
      return `已保存 ${formatEpoch(this.recordUpdatedAt)}`;
    }
    return '尚未保存';
  }

  async saveDraft(): Promise<boolean> {
    if (this.saving) {
      return false;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap());
      this.applyRecord(record);
      this.dirty = false;
      this.conflicted = false;
      this.notice = `草稿已保存（已填 ${record.filled}/${record.totalSections} 段）`;
      this.noticeTone = 'success';
      return true;
    } catch (error) {
      this.handleError(error as Error);
      return false;
    } finally {
      this.saving = false;
    }
  }

  async lock(): Promise<void> {
    if (this.saving || this.locked) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      // 提交锁定前先保存页面上的新修改，避免锁到旧内容（服务端按内容快照做乐观锁）。
      if (this.dirty) {
        const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap());
        this.applyRecord(record);
        this.dirty = false;
      }
      const locked = await this.repository.lockRecord(this.appointmentId);
      this.applyRecord(locked);
      this.conflicted = false;
      this.notice = '病历已提交锁定，锁定后不可修改';
      this.noticeTone = 'success';
    } catch (error) {
      // 保存成功、锁定失败时：已确认保存的版本已落到本地（dirty 已清），保留该版本并提示。
      this.handleError(error as Error);
    } finally {
      this.saving = false;
    }
  }

  async prefill(): Promise<void> {
    if (this.saving || this.locked) {
      return;
    }
    const sessionId = this.previsit.sessionId;
    if (sessionId.length === 0) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap(), sessionId);
      this.applyRecord(record);
      this.dirty = false;
      this.conflicted = false;
      this.notice = '已用预问诊单预填（use_intake_session，仅首次）';
      this.noticeTone = 'success';
    } catch (error) {
      this.handleError(error as Error);
    } finally {
      this.saving = false;
    }
  }

  async finish(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      await this.repository.finishVisit(this.appointmentId);
      AppRouter.getInstance().back();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
      this.saving = false;
    }
  }

  // 预问诊槽位 → 病历段 key（与后端 intakePrefill 的合成规则一致）。
  private emrSectionKeyForSlot(slotKey: string): string {
    if (slotKey === 'chief') {
      return 'chief_complaint';
    }
    if (slotKey === 'duration' || slotKey === 'severity' || slotKey === 'associated') {
      return 'present_illness';
    }
    if (slotKey === 'history') {
      return 'past_history';
    }
    if (slotKey === 'allergy') {
      return 'allergy_history';
    }
    return '';
  }

  // 多来源合成进「现病史」时带标签前缀，其余槽位直接取原话。
  private adoptText(slot: PrevisitSlot): string {
    if (slot.key === 'duration' || slot.key === 'severity' || slot.key === 'associated') {
      return `${slot.label}：${slot.value}`;
    }
    return slot.value;
  }

  private sectionIndex(key: string): number {
    for (let i = 0; i < this.sections.length; i++) {
      if (this.sections[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  // 「采纳到本段」：追加到对应病历段，绝不覆盖医生已有内容。
  private adopt(slot: PrevisitSlot): void {
    const targetKey = this.emrSectionKeyForSlot(slot.key);
    const index = this.sectionIndex(targetKey);
    if (index < 0) {
      return;
    }
    const piece = this.adoptText(slot);
    const current = this.values[index] ?? '';
    this.values[index] = current.length === 0 ? piece : `${current}\n${piece}`;
    this.dirty = true;
    this.conflicted = false;
    this.notice = `已把「${slot.label}」采纳到病历（追加，未覆盖）`;
    this.noticeTone = 'success';
  }

  build() {
    Column() {
      PageHeader({
        title: `电子病历 · 序号 ${this.seq}`,
        showBack: true
      })

      Row() {
        Text(this.statusText())
          .fontSize(AppText.CAPTION)
          .fontColor(this.conflicted || this.dirty ? AppColor.WARNING : AppColor.TEXT_SECONDARY)
          .layoutWeight(1)
        if (this.conflicted) {
          Button('重新加载')
            .height(30)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.PRIMARY)
            .backgroundColor(AppColor.PRIMARY_SOFT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onClick(() => this.load())
        }
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (this.sections.length === 0) {
            EmptyState({ title: '暂无病历段落', description: '服务端未返回七段结构' })
          } else {
            if (this.hasPrevisitSummary && this.previsit.sections.length > 0) {
              Column() {
                Row() {
                  Text(this.previsit.bound ? '患者自述 · 本次就诊预问诊' : '患者自述 · 该患者最近一次预问诊')
                    .fontSize(AppText.SUBHEADING)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  Text(`已答 ${this.previsit.filled}/${this.previsit.total}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                }
                .width('100%')

                ForEach(this.previsit.sections, (slot: PrevisitSlot) => {
                  Row() {
                    Column() {
                      Text(slot.label)
                        .fontSize(AppText.CAPTION)
                        .fontColor(AppColor.TEXT_SECONDARY)
                      Text(slot.value)
                        .fontSize(AppText.BODY)
                        .fontColor(AppColor.TEXT)
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Button('采纳')
                      .height(30)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .enabled(!this.locked && !this.saving)
                      .onClick(() => this.adopt(slot))
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .margin({ top: AppSize.GAP })
                }, (slot: PrevisitSlot) => slot.key)
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: AppSize.GAP })
            }

            if (!this.locked && this.hasPrevisitSummary && this.previsit.sessionId.length > 0) {
              InfoBanner({
                message: '可由预问诊单预填（use_intake_session，仅首次）',
                tone: 'info',
                actionText: '一键预填',
                onAction: () => this.prefill()
              })
                .margin({ bottom: AppSize.GAP })
            }

            ForEach(this.sections, (section: EmrSection, index: number) => {
              Column() {
                Row() {
                  Row() {
                    Text(section.label)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    if (section.requiredToLock) {
                      Text(' 必填锁定')
                        .fontSize(AppText.CAPTION)
                        .fontColor(AppColor.DANGER)
                    }
                    if (this.previsitRefSections.indexOf(section.key) >= 0) {
                      Text(' 患者自述（已由医生编辑）')
                        .fontSize(AppText.CAPTION)
                        .fontColor(AppColor.INFO)
                    }
                  }
                  .layoutWeight(1)

                  Text(`${(this.values[index] ?? '').length}/${section.maxLen}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                }
                .width('100%')

                TextArea({
                  placeholder: `请输入${section.label}`,
                  text: this.values[index] ?? ''
                })
                  .width('100%')
                  .height(96)
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.TEXT)
                  .backgroundColor(AppColor.SURFACE_ALT)
                  .borderRadius(AppSize.CARD_RADIUS)
                  .maxLength(section.maxLen)
                  .enabled(!this.locked && !this.saving)
                  .margin({ top: 8 })
                  .onChange((value: string) => {
                    this.values[index] = value;
                    this.dirty = true;
                    this.conflicted = false;
                  })

                if (section.requiredToLock) {
                  Text(`「${section.label}」为锁定必填段，未填不可锁定`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .margin({ top: 6 })
                }
              }
              .width('100%')
              .margin({ bottom: AppSize.GAP })
            }, (section: EmrSection) => section.key)

            if (this.locked) {
              InfoBanner({
                message: '已提交锁定，仅管理员可 reopen，医生不可修改',
                tone: 'warning'
              })
                .margin({ top: 4, bottom: AppSize.GAP })

              Button(this.saving ? '提交中…' : '完成就诊')
                .width('100%')
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.SURFACE)
                .backgroundColor(AppColor.PRIMARY)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .enabled(!this.saving)
                .onClick(() => this.finish())
            } else {
              Row() {
                Button(this.saving ? '保存中…' : '保存草稿')
                  .layoutWeight(1)
                  .height(AppSize.CONTROL_HEIGHT)
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.PRIMARY)
                  .backgroundColor(AppColor.PRIMARY_SOFT)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .enabled(!this.saving)
                  .onClick(() => this.saveDraft())
                Button(this.saving ? '提交中…' : '提交锁定')
                  .layoutWeight(1)
                  .height(AppSize.CONTROL_HEIGHT)
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.SURFACE)
                  .backgroundColor(AppColor.PRIMARY)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .enabled(!this.saving)
                  .margin({ left: AppSize.GAP })
                  .onClick(() => this.lock())
              }
              .width('100%')
              .margin({ top: 4 })

              Text('锁定后不可修改，仅管理员可 reopen')
                .width('100%')
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.WARNING)
                .margin({ top: AppSize.GAP })
            }
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 })
    .backgroundColor(AppColor.BACKGROUND)
  }
}
