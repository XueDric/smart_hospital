import {
  ApiError,
  AppColor,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip,
  formatEpoch
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { KbDoc } from '../model/AdminModels';

@ComponentV2
export struct KnowledgeBasePage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local docs: KbDoc[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local keyword: string = '';
  @Local createTitle: string = '';
  @Local createCategory: string = '';
  @Local createBody: string = '';
  @Local editingId: number = 0;
  @Local editTitle: string = '';
  @Local editCategory: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.docs = await this.repository.kbDocs();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private filtered(): KbDoc[] {
    const query = this.keyword.trim();
    if (query.length === 0) {
      return this.docs;
    }
    const result: KbDoc[] = [];
    for (const doc of this.docs) {
      if (doc.title.indexOf(query) >= 0) {
        result.push(doc);
      }
    }
    return result;
  }

  async create(): Promise<void> {
    if (this.createTitle.trim().length === 0 || this.createBody.trim().length === 0) {
      this.notice = '标题与正文均必填';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'title': this.createTitle.trim(),
      'category': this.createCategory.trim(),
      'body': this.createBody.trim()
    };
    this.notice = '';
    try {
      const created = await this.repository.createKbDoc(body);
      this.notice = `文档已上传并切块（${created.chunkCount} 块）`;
      this.noticeTone = 'success';
      this.createTitle = '';
      this.createCategory = '';
      this.createBody = '';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  private edit(item: KbDoc): void {
    this.editingId = item.id;
    this.editTitle = item.title;
    this.editCategory = item.category;
    this.notice = '';
  }

  async saveEdit(item: KbDoc): Promise<void> {
    if (this.editTitle.trim().length === 0) {
      this.notice = '标题不能为空';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'title': this.editTitle.trim(),
      'category': this.editCategory.trim(),
      'enabled': item.enabled
    };
    this.notice = '';
    try {
      await this.repository.updateKbDoc(item.id, body);
      this.notice = '文档已更新';
      this.noticeTone = 'success';
      this.editingId = 0;
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async remove(item: KbDoc): Promise<void> {
    this.notice = '';
    try {
      await this.repository.deleteKbDoc(item.id);
      this.notice = '文档已删除';
      this.noticeTone = 'success';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  build() {
    Column() {
      Text('知识库管理')
        .fontSize(AppText.HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 20, bottom: 12 })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Column() {
        SectionTitle({ title: '新增文档' })

        Row() {
          TextInput({ placeholder: '标题', text: this.createTitle })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.createTitle = value;
            })
          TextInput({ placeholder: '分类', text: this.createCategory })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onChange((value: string) => {
              this.createCategory = value;
            })
        }
        .width('100%')

        TextArea({ placeholder: '正文（切块后进入检索）', text: this.createBody })
          .width('100%')
          .height(96)
          .fontSize(AppText.BODY)
          .backgroundColor(AppColor.SURFACE_ALT)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: AppSize.GAP })
          .onChange((value: string) => {
            this.createBody = value;
          })

        Button('新增文档')
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .fontColor(AppColor.SURFACE)
          .backgroundColor(AppColor.PRIMARY)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .margin({ top: AppSize.GAP })
          .onClick(() => this.create())
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
      .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })

      Row() {
        TextInput({ placeholder: '输入关键词过滤文档（关键词检索为默认路）', text: this.keyword })
          .layoutWeight(1)
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP })
          .onChange((value: string) => {
            this.keyword = value;
          })
      }
      .width('100%')

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (this.filtered().length === 0) {
            EmptyState({ title: '无匹配文档' })
          } else {
            ForEach(this.filtered(), (item: KbDoc) => {
              Column() {
                Row() {
                  Column() {
                    Text(`#${item.id} ${item.title}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(`${item.category || '未分类'} · ${item.chunkCount} 块 · ${formatEpoch(item.updatedAt)}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  StatusChip({
                    text: item.enabled ? '启用' : '停用',
                    color: item.enabled ? AppColor.SUCCESS : AppColor.TEXT_SECONDARY,
                    chipBackground: item.enabled ? AppColor.SUCCESS_SOFT : AppColor.SURFACE_ALT
                  })
                }
                .width('100%')

                if (this.editingId === item.id) {
                  Row() {
                    TextInput({ placeholder: '标题', text: this.editTitle })
                      .layoutWeight(1)
                      .height(AppSize.CONTROL_HEIGHT)
                      .fontSize(AppText.BODY)
                      .backgroundColor(AppColor.SURFACE_ALT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onChange((value: string) => {
                        this.editTitle = value;
                      })
                    TextInput({ placeholder: '分类', text: this.editCategory })
                      .layoutWeight(1)
                      .height(AppSize.CONTROL_HEIGHT)
                      .fontSize(AppText.BODY)
                      .backgroundColor(AppColor.SURFACE_ALT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onChange((value: string) => {
                        this.editCategory = value;
                      })
                  }
                  .width('100%')
                  .margin({ top: AppSize.GAP })

                  Row() {
                    Button('保存')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.PRIMARY)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.saveEdit(item))
                    Button('取消')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .backgroundColor(AppColor.SURFACE_ALT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => {
                        this.editingId = 0;
                      })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                  .margin({ top: AppSize.GAP })
                } else {
                  Row() {
                    Button('编辑')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.PRIMARY)
                      .backgroundColor(AppColor.PRIMARY_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onClick(() => this.edit(item))
                    Button('删除')
                      .height(36)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.DANGER)
                      .backgroundColor(AppColor.DANGER_SOFT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.remove(item))
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.End)
                  .margin({ top: AppSize.GAP })
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: AppSize.GAP })
            }, (item: KbDoc) => `${item.id}`)
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
