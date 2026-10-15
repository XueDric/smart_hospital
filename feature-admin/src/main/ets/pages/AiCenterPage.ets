import {
  ApiError,
  AppColor,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { AiPrompt, AiSetting, AiTool } from '../model/AdminModels';

@ComponentV2
export struct AiCenterPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local aiTab: string = 'settings';
  @Local settings: AiSetting[] = [];
  @Local prompts: AiPrompt[] = [];
  @Local tools: AiTool[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local editingSettingKey: string = '';
  @Local editingSettingValue: string = '';
  @Local editingPromptName: string = '';
  @Local editingPromptBody: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.settings = await this.repository.aiSettings();
      this.prompts = await this.repository.aiPrompts();
      this.tools = await this.repository.aiTools();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private beginEditSetting(item: AiSetting): void {
    this.editingSettingKey = item.key;
    this.editingSettingValue = item.secret ? '' : item.value;
    this.notice = '';
  }

  private beginEditPrompt(item: AiPrompt): void {
    this.editingPromptName = item.name;
    this.editingPromptBody = item.body;
    this.notice = '';
  }

  async saveSetting(item: AiSetting): Promise<void> {
    const value = this.editingSettingValue.trim();
    if (value.length === 0) {
      this.notice = '配置值不能为空';
      this.noticeTone = 'error';
      return;
    }
    this.notice = '';
    try {
      await this.repository.updateAiSetting(item.key, value);
      this.notice = '配置已保存并即时生效（写库 → 失效缓存，零重启）';
      this.noticeTone = 'success';
      this.editingSettingKey = '';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async savePrompt(item: AiPrompt): Promise<void> {
    const body = this.editingPromptBody.trim();
    if (body.length === 0) {
      this.notice = '提示词模板不能为空';
      this.noticeTone = 'error';
      return;
    }
    this.notice = '';
    try {
      await this.repository.updateAiPrompt(item.name, body);
      this.notice = '提示词模板已更新';
      this.noticeTone = 'success';
      this.editingPromptName = '';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async resetPrompt(item: AiPrompt): Promise<void> {
    this.notice = '';
    try {
      await this.repository.deleteAiPrompt(item.name);
      this.notice = '已重置为默认模板';
      this.noticeTone = 'success';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async toggleTool(item: AiTool): Promise<void> {
    this.notice = '';
    try {
      await this.repository.updateAiTool(item.name, !item.enabled);
      this.notice = '工具开关已更新（enabled 只接受 JSON 布尔）';
      this.noticeTone = 'success';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  build() {
    Column() {
      Text('AI 能力中心')
        .fontSize(AppText.HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 20, bottom: 12 })

      Row() {
        this.tabButton('settings', '模型配置')
        this.tabButton('prompts', 'Prompt 模板')
        this.tabButton('tools', '工具开关')
      }
      .width('100%')
      .padding(3)
      .backgroundColor(AppColor.SURFACE_ALT)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (this.aiTab === 'settings') {
            this.settingsTab()
          } else if (this.aiTab === 'prompts') {
            this.promptsTab()
          } else {
            this.toolsTab()
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
  }

  @Builder
  tabButton(value: string, label: string) {
    Button(label)
      .layoutWeight(1)
      .height(AppSize.TOUCH_MIN)
      .fontSize(AppText.CAPTION)
      .fontColor(this.aiTab === value ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
      .backgroundColor(this.aiTab === value ? AppColor.PRIMARY_SOFT : Color.Transparent)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .onClick(() => {
        this.aiTab = value;
      })
  }

  @Builder
  settingsTab() {
    Column() {
      if (this.settings.length === 0) {
        EmptyState({ title: '暂无配置' })
      } else {
        ForEach(this.settings, (item: AiSetting) => {
          Column() {
            Row() {
              Column() {
                Text(item.key)
                  .fontSize(AppText.SUBHEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.TEXT)
                if (item.secret) {
                  Text(item.value)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.WARNING)
                    .margin({ top: 4 })
                } else {
                  Text(item.value)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .margin({ top: 4 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.editingSettingKey === item.key) {
                Button('保存')
                  .height(AppSize.TOUCH_MIN)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.SURFACE)
                  .backgroundColor(AppColor.PRIMARY)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .onClick(() => this.saveSetting(item))
              } else {
                Button('编辑')
                  .height(AppSize.TOUCH_MIN)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.PRIMARY)
                  .backgroundColor(AppColor.PRIMARY_SOFT)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .onClick(() => this.beginEditSetting(item))
              }
            }
            .width('100%')

            if (this.editingSettingKey === item.key) {
              TextInput({
                placeholder: item.secret ? '请输入 env: 或 file: 引用（裸密钥会被拒绝）' : '请输入配置值',
                text: this.editingSettingValue
              })
                .width('100%')
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .backgroundColor(AppColor.SURFACE_ALT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .margin({ top: AppSize.GAP })
                .onChange((value: string) => {
                  this.editingSettingValue = value;
                })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ bottom: AppSize.GAP })
        }, (item: AiSetting) => item.key)
      }

      InfoBanner({
        message: '改配置零重启：写库 → 失效缓存；密钥只存引用（env: / file:），裸密钥被机制性拒绝，回显一律脱敏',
        tone: 'info'
      })
    }
    .width('100%')
  }

  @Builder
  promptsTab() {
    Column() {
      if (this.prompts.length === 0) {
        EmptyState({ title: '暂无提示词模板' })
      } else {
        ForEach(this.prompts, (item: AiPrompt) => {
          Column() {
            Row() {
              Column() {
                Text(item.name)
                  .fontSize(AppText.SUBHEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.TEXT)
                Text(`占位符：${item.required.join(' / ')}`)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              StatusChip({
                text: item.customized ? '已自定义' : '默认',
                color: item.customized ? AppColor.WARNING : AppColor.TEXT_SECONDARY,
                chipBackground: item.customized ? AppColor.WARNING_SOFT : AppColor.SURFACE_ALT
              })
            }
            .width('100%')

            Text(item.body)
              .width('100%')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT)
              .backgroundColor(AppColor.SURFACE_ALT)
              .padding(10)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ top: AppSize.GAP })

            Row() {
              Button('编辑')
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.PRIMARY)
                .backgroundColor(AppColor.PRIMARY_SOFT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .onClick(() => this.beginEditPrompt(item))
              Button('重置为默认')
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.DANGER)
                .backgroundColor(AppColor.DANGER_SOFT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .margin({ left: AppSize.GAP })
                .onClick(() => this.resetPrompt(item))
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: AppSize.GAP })

            if (this.editingPromptName === item.name) {
              TextArea({ placeholder: '请输入提示词模板（含占位符）', text: this.editingPromptBody })
                .width('100%')
                .height(120)
                .fontSize(AppText.BODY)
                .backgroundColor(AppColor.SURFACE_ALT)
                .borderRadius(AppSize.CARD_RADIUS)
                .margin({ top: AppSize.GAP })
                .onChange((value: string) => {
                  this.editingPromptBody = value;
                })
              Button('保存模板')
                .width('100%')
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .fontColor(AppColor.SURFACE)
                .backgroundColor(AppColor.PRIMARY)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .margin({ top: AppSize.GAP })
                .onClick(() => this.savePrompt(item))
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ bottom: AppSize.GAP })
        }, (item: AiPrompt) => item.name)
      }
    }
    .width('100%')
  }

  @Builder
  toolsTab() {
    Column() {
      if (this.tools.length === 0) {
        EmptyState({ title: '暂无工具' })
      } else {
        ForEach(this.tools, (item: AiTool) => {
          Column() {
            Row() {
              Column() {
                Text(item.name)
                  .fontSize(AppText.SUBHEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.TEXT)
                Text(item.label)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Button(item.enabled ? '已开启' : '已关闭')
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(item.enabled ? AppColor.SURFACE : AppColor.TEXT_SECONDARY)
                .backgroundColor(item.enabled ? AppColor.PRIMARY : AppColor.SURFACE_ALT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .onClick(() => this.toggleTool(item))
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ bottom: AppSize.GAP })
        }, (item: AiTool) => item.name)
      }
    }
    .width('100%')
  }
}
