import { ApiError, AppRouter, ErrorCode, RouteName, SessionStore } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import {
  PrevisitSession,
  PrevisitSlots,
  SlotDefinition
} from '../model/PatientModels';
import { AppButton, InfoBanner, PageHeader } from 'common-core';
import { AppColor, AppSize, AppText } from 'common-core';

class ChatMessage {
  role: string = '';
  text: string = '';
  streaming: boolean = false;

  constructor(role: string, text: string, streaming: boolean = false) {
    this.role = role;
    this.text = text;
    this.streaming = streaming;
  }
}

@ComponentV2
export struct PrevisitPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local chiefComplaint: string = '';
  @Local answer: string = '';
  @Local messages: ChatMessage[] = [];
  @Local sessionId: string = '';
  @Local session: PrevisitSession = new PrevisitSession();
  @Local streaming: boolean = false;
  @Local sending: boolean = false;
  @Local errorMessage: string = '';
  @Local restored: boolean = false;

  aboutToAppear(): void {
    this.restoreSession();
  }

  async restoreSession(): Promise<void> {
    const savedSessionId = SessionStore.getPrevisitSessionId();
    if (savedSessionId.length === 0) {
      this.restored = true;
      return;
    }
    this.sessionId = savedSessionId;
    try {
      this.session = await this.repository.getPrevisit(savedSessionId);
      if (this.session.complete) {
        this.buildSummaryMessages();
      } else {
        this.messages = [
          new ChatMessage('assistant', this.session.nextQuestion)
        ];
      }
    } catch (error) {
      const apiError = ApiError.from(error as Error);
      if (apiError.code === ErrorCode.PREVISIT_NOT_FOUND) {
        SessionStore.setPrevisitSessionId('');
        this.sessionId = '';
      } else {
        this.errorMessage = apiError.userMessage();
      }
    } finally {
      this.restored = true;
    }
  }

  async startStream(): Promise<void> {
    if (this.streaming) {
      return;
    }
    if (this.chiefComplaint.trim().length === 0) {
      this.errorMessage = '请先填写本次主要不适';
      return;
    }
    this.errorMessage = '';
    this.streaming = true;
    this.messages = [new ChatMessage('user', this.chiefComplaint.trim())];
    this.appendAssistant('', true);
    try {
      await this.repository.openPrevisitStream(this.chiefComplaint.trim(), {
        onMeta: (sessionId: string) => {
          this.sessionId = sessionId;
          SessionStore.setPrevisitSessionId(sessionId);
        },
        onDelta: (text: string) => {
          this.appendStreamingDelta(text);
        },
        onDone: () => {
          this.finishStreaming();
        }
      });
      await this.refreshSession();
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.streaming = false;
      this.finishStreaming();
    }
  }

  async submitAnswer(): Promise<void> {
    if (this.sending || this.streaming || this.session.complete || this.session.nextSlot.length === 0) {
      return;
    }
    const slot: SlotDefinition = PrevisitSlots.find(this.session.nextSlot);
    const value = this.answer.trim();
    if (value.length === 0) {
      this.errorMessage = '请填写答案；没有相关情况可填写「无」';
      return;
    }
    if (slot.maxLen > 0 && value.length > slot.maxLen) {
      this.errorMessage = `${slot.label}最多 ${slot.maxLen} 个字符`;
      return;
    }
    this.sending = true;
    this.errorMessage = '';
    const nextMessages = this.messages.slice();
    nextMessages.push(new ChatMessage('user', value));
    this.messages = nextMessages;
    this.answer = '';
    try {
      this.session = await this.repository.answerPrevisit(this.sessionId, this.session.nextSlot, value);
      if (this.session.complete) {
        this.buildSummaryMessages();
      } else {
        const updated = this.messages.slice();
        updated.push(new ChatMessage('assistant', this.session.nextQuestion));
        this.messages = updated;
      }
    } catch (error) {
      const apiError = ApiError.from(error as Error);
      if (apiError.code === ErrorCode.PREVISIT_NOT_FOUND) {
        SessionStore.setPrevisitSessionId('');
        this.sessionId = '';
        this.session = new PrevisitSession();
        this.messages = [];
      }
      this.errorMessage = apiError.userMessage();
    } finally {
      this.sending = false;
    }
  }

  private async refreshSession(): Promise<void> {
    if (this.sessionId.length === 0) {
      throw new ApiError(ErrorCode.SSE_INCOMPLETE, '预问诊会话创建失败');
    }
    this.session = await this.repository.getPrevisit(this.sessionId);
    if (this.session.complete) {
      this.buildSummaryMessages();
      return;
    }
    const updated = this.messages.slice();
    updated.push(new ChatMessage('assistant', this.session.nextQuestion));
    this.messages = updated;
  }

  private buildSummaryMessages(): void {
    this.messages = [new ChatMessage('assistant', '六项信息已采集完成，预问诊单已生成。')];
  }

  private appendAssistant(text: string, streaming: boolean): void {
    const updated = this.messages.slice();
    updated.push(new ChatMessage('assistant', text, streaming));
    this.messages = updated;
  }

  private appendStreamingDelta(text: string): void {
    if (this.messages.length === 0) {
      this.appendAssistant(text, true);
      return;
    }
    const updated = this.messages.slice();
    const last = updated[updated.length - 1];
    updated[updated.length - 1] = new ChatMessage(last.role, last.text + text, last.streaming);
    this.messages = updated;
  }

  private finishStreaming(): void {
    if (this.messages.length === 0) {
      return;
    }
    const updated = this.messages.slice();
    const last = updated[updated.length - 1];
    updated[updated.length - 1] = new ChatMessage(last.role, last.text, false);
    this.messages = updated;
  }

  private restart(): void {
    SessionStore.setPrevisitSessionId('');
    this.sessionId = '';
    this.session = new PrevisitSession();
    this.messages = [];
    this.chiefComplaint = '';
    this.answer = '';
    this.errorMessage = '';
  }

  build() {
    Column() {
      PageHeader({
        title: '智能预问诊',
        subtitle: this.session.complete ? '问诊单已完成' :
          (this.session.totalSlots > 0 ? `已完成 ${this.session.filled}/${this.session.totalSlots} 项` : '六轮信息采集')
      })

      if (this.messages.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.messages, (message: ChatMessage) => {
              Row() {
                if (message.role === 'user') {
                  Blank()
                }
                Column() {
                  Text(message.role === 'user' ? '我' : '预问诊助手')
                    .fontSize(AppText.CAPTION)
                    .fontColor(message.role === 'user' ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                    .width('100%')
                  Text(message.text.length > 0 ? message.text : (this.streaming ? '正在输入…' : ''))
                    .fontSize(AppText.BODY)
                    .fontColor(message.role === 'user' ? AppColor.SURFACE : AppColor.TEXT)
                    .lineHeight(23)
                    .width('100%')
                    .margin({ top: 5 })
                }
                .width('78%')
                .padding(12)
                .backgroundColor(message.role === 'user' ? AppColor.PRIMARY : AppColor.SURFACE)
                .borderRadius(AppSize.CARD_RADIUS)
                if (message.role !== 'user') {
                  Blank()
                }
              }
              .width('100%')
              .margin({ bottom: 12 })
            })
          }
          .width('100%')
          .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 8, bottom: 12 })
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        Scroll() {
          Column() {
            InfoBanner({
              message: '预问诊会依次采集主诉、持续时间、影响程度、伴随症状、既往史和过敏史。',
              tone: 'info'
            })
            TextArea({
              placeholder: '请描述本次主要不适，例如：咳嗽三天，咽喉疼痛',
              text: this.chiefComplaint
            })
              .width('100%')
              .height(140)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .maxLength(200)
              .margin({ top: AppSize.GAP })
              .onChange((value: string) => {
                this.chiefComplaint = value;
              })
          }
          .width('100%')
          .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
      }

      if (this.errorMessage.length > 0) {
        InfoBanner({ message: this.errorMessage, tone: 'error' })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 8 })
      }

      if (this.session.complete) {
        this.summary()
      } else {
        Column() {
          if (this.messages.length === 0) {
            AppButton({
              text: this.streaming ? '正在建立预问诊…' : '开始预问诊',
              isEnabled: !this.streaming,
              onTap: () => this.startStream()
            })
          } else {
            if (this.session.nextSlot.length > 0) {
              Text(`${PrevisitSlots.label(this.session.nextSlot)} · 最多 ${PrevisitSlots.find(this.session.nextSlot).maxLen} 字`)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
                .width('100%')
                .margin({ bottom: 6 })
            }
            Row() {
              TextInput({
                placeholder: this.session.nextSlot.length > 0 ?
                  PrevisitSlots.find(this.session.nextSlot).hint : '正在加载下一项',
                text: this.answer
              })
                .layoutWeight(1)
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .backgroundColor(AppColor.SURFACE_ALT)
                .borderRadius(AppSize.CONTROL_RADIUS)
                .enabled(!this.sending && !this.streaming && this.session.nextSlot.length > 0)
                .onChange((value: string) => {
                  this.answer = value;
                })
              Button('无')
                .width(56)
                .height(AppSize.CONTROL_HEIGHT)
                .fontSize(AppText.BODY)
                .fontColor(AppColor.PRIMARY_DARK)
                .backgroundColor(AppColor.PRIMARY_SOFT)
                .margin({ left: 8 })
                .enabled(this.session.nextSlot !== 'chief' && !this.sending && !this.streaming)
                .onClick(() => {
                  this.answer = '无';
                })
            }
            .width('100%')
            AppButton({
              text: this.sending ? '正在提交…' : '提交并继续',
              isEnabled: !this.sending && !this.streaming && this.session.nextSlot.length > 0,
              onTap: () => this.submitAnswer()
            })
              .margin({ top: 10 })
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 18 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  summary() {
    Scroll() {
      Column() {
        Text('预问诊摘要')
          .fontSize(AppText.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')
        ForEach(PrevisitSlots.ALL, (slot: SlotDefinition) => {
          Row() {
            Text(slot.label)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width(72)
            Text(this.session.form[slot.key] ?? '')
              .fontSize(AppText.BODY)
              .fontColor(AppColor.TEXT)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .border({ width: { bottom: 1 }, color: AppColor.BORDER })
        })
        AppButton({
          text: '去预约挂号',
          onTap: () => AppRouter.getInstance().reset(RouteName.BOOKING)
        })
          .margin({ top: AppSize.GAP })
        AppButton({
          text: '重新预问诊',
          secondary: true,
          onTap: () => this.restart()
        })
          .margin({ top: 10 })
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 20 })
    }
    .height(280)
    .width('100%')
  }
}
