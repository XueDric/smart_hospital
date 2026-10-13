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
  asNumber
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { EmrSection } from '../model/DoctorModels';

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
  @Local notice: string = '';
  @Local noticeTone: string = 'info';

  aboutToAppear(): void {
    const params = AppRouter.getInstance().getParams();
    this.appointmentId = asNumber(params['appointmentId']);
    this.seq = asNumber(params['seq']);
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      const record = await this.repository.getRecord(this.appointmentId);
      this.sections = record.sections;
      this.values = [];
      for (const section of record.sections) {
        this.values.push(section.value);
      }
      this.locked = record.locked;
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private valuesMap(): Record<string, string> {
    const result: Record<string, string> = {};
    for (let i = 0; i < this.sections.length; i++) {
      result[this.sections[i].key] = this.values[i] ?? '';
    }
    return result;
  }

  async saveDraft(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap());
      this.sections = record.sections;
      this.values = [];
      for (const section of record.sections) {
        this.values.push(section.value);
      }
      this.locked = record.locked;
      this.notice = `草稿已保存（已填 ${record.filled}/${record.totalSections} 段）`;
      this.noticeTone = 'success';
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.saving = false;
    }
  }

  async lock(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.lockRecord(this.appointmentId);
      this.sections = record.sections;
      this.values = [];
      for (const section of record.sections) {
        this.values.push(section.value);
      }
      this.locked = record.locked;
      this.notice = '病历已提交锁定，锁定后不可修改';
      this.noticeTone = 'success';
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.saving = false;
    }
  }

  async prefill(): Promise<void> {
    if (this.saving || this.locked) {
      return;
    }
    const sessionId = SessionStore.getPrevisitSessionId();
    if (sessionId.length === 0) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap(), sessionId);
      this.sections = record.sections;
      this.values = [];
      for (const section of record.sections) {
        this.values.push(section.value);
      }
      this.notice = '已用预问诊单预填（use_intake_session，仅首次）';
      this.noticeTone = 'success';
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
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

  private hasPrevisit(): boolean {
    return SessionStore.getPrevisitSessionId().length > 0;
  }

  build() {
    Column() {
      PageHeader({
        title: `电子病历 · 序号 ${this.seq}`,
        showBack: true
      })

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
            if (!this.locked && this.hasPrevisit()) {
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
                  .enabled(!this.locked)
                  .margin({ top: 8 })
                  .onChange((value: string) => {
                    this.values[index] = value;
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
