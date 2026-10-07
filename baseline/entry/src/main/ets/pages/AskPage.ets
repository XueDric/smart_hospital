// 负责人：杨睿（前端组长）
// 「问一问」—— 权限感知问答。回答下方必须展示 basis（依据），让用户知道答案从哪来。
// 纪律：20s 超时按 none 呈现；离开页面丢弃回填；按钮置灰 + in-flight 去重；只给手动重试。

import { AiApi, AskBasis, AgentProposal, AgentStep, AgentDiffLine } from '../api/AiApi';
import { AiCard } from '../components/AiCard';
import { Color, FontSize, Radius, Shadow, Space, StatusColor, statusLabel } from '../core/Theme';
import { backPage } from '../utils/RouterUtils';

const ASK_TIMEOUT_MS: number = 20000;
// 智能体比 ask 慢（最多 4 轮模型调用，服务端总预算 20s），客户端超时预算放宽到 25s
const AGENT_TIMEOUT_MS: number = 25000;

function basisKindLabel(kind: string): string {
  if (kind === 'permission') return '权限';
  if (kind === 'data') return '数据';
  if (kind === 'doc') return '章程';
  return '依据';
}

function diffFieldLabel(field: string): string {
  if (field === 'status') return '状态';
  if (field === 'blocker') return '阻塞原因';
  return field;
}

function diffValueLabel(field: string, value: string): string {
  if (field === 'status') return statusLabel(value);
  return value;
}

@Entry
@Component
struct AskPage {
  @State question: string = '';
  @State loading: boolean = false;
  @State asked: boolean = false;
  @State source: string = 'none';
  @State note: string = '';
  @State answer: string = '';
  @State basisItems: string[] = [];
  @State errorMsg: string = '';
  // 智能体模式（先查数据再回答）：步骤时间线 + 待确认提议
  @State useAgent: boolean = false;
  @State agentSteps: AgentStep[] = [];
  @State agentCalls: number = 0;
  @State stepsExpanded: boolean = false;
  @State proposal: AgentProposal | null = null;
  @State confirmLoading: boolean = false;
  @State confirmError: string = '';
  @State confirmedSummary: string = '';

  private aiApi: AiApi = new AiApi();
  private askSeq: number = 0;
  private timeoutTimer: number = -1;

  aboutToDisappear(): void {
    // 离开页面：丢弃回填（自增序号，让在途请求的结果作废）
    this.askSeq += 1;
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timeoutTimer !== -1) {
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = -1;
    }
  }

  private basisLines(basis: AskBasis[]): string[] {
    return basis.map((b: AskBasis): string => `${basisKindLabel(b.kind)} · ${b.ref}`);
  }

  async submit(): Promise<void> {
    const q: string = this.question.trim();
    if (q.length === 0 || this.loading || this.confirmLoading) {
      return;
    }
    this.loading = true;
    this.asked = true;
    this.errorMsg = '';
    this.source = 'none';
    this.note = '';
    this.answer = '';
    this.basisItems = [];
    this.agentSteps = [];
    this.agentCalls = 0;
    this.stepsExpanded = false;
    this.proposal = null;
    this.confirmError = '';
    this.confirmedSummary = '';
    const seq: number = ++this.askSeq;

    // 到点按 source=none 呈现，不弹错、不留 loading（智能体更慢，预算放宽到 25s）
    this.clearTimer();
    const timeout: number = this.useAgent ? AGENT_TIMEOUT_MS : ASK_TIMEOUT_MS;
    this.timeoutTimer = setTimeout(() => {
      if (seq === this.askSeq && this.loading) {
        this.loading = false;
        this.source = 'none';
      }
    }, timeout);

    if (this.useAgent) {
      const resp = await this.aiApi.agent(q);
      if (seq !== this.askSeq) {
        return; // 已被新请求或离开页面取代，丢弃回填
      }
      this.clearTimer();
      this.loading = false;

      if (resp.ok && resp.data !== undefined) {
        this.source = resp.data.source;
        this.note = resp.data.note ?? '';
        this.answer = resp.data.answer;
        this.basisItems = this.basisLines(resp.data.basis);
        this.agentSteps = resp.data.steps ?? [];
        this.agentCalls = resp.data.calls;
        this.proposal = resp.data.proposal ?? null;
      } else {
        this.errorMsg = resp.error?.message ?? '提问失败，请稍后重试';
      }
      return;
    }

    const resp = await this.aiApi.ask(q);
    if (seq !== this.askSeq) {
      return; // 已被新请求或离开页面取代，丢弃回填
    }
    this.clearTimer();
    this.loading = false;

    if (resp.ok && resp.data !== undefined) {
      this.source = resp.data.source;
      this.note = resp.data.note ?? '';
      this.answer = resp.data.answer;
      this.basisItems = this.basisLines(resp.data.basis);
    } else {
      this.errorMsg = resp.error?.message ?? '提问失败，请稍后重试';
    }
  }

  /** 确认并执行 AI 提议 —— 写操作，失败语义与读接口分家，必须显式展示（§10.8 四档错误码） */
  async confirmProposal(): Promise<void> {
    if (this.proposal === null || this.confirmLoading) {
      return;
    }
    this.confirmLoading = true;
    this.confirmError = '';
    const token: string = this.proposal.token;
    const resp = await this.aiApi.confirm(token);
    this.confirmLoading = false;

    if (resp.ok && resp.data !== undefined) {
      this.confirmedSummary = resp.data.summary;
      this.proposal = null;
      return;
    }

    const code: string = resp.error?.code ?? '';
    if (code === 'AI_PROPOSAL_USED') {
      // 已消费（重复点确认）：不算错误，刷新状态即可
      this.confirmedSummary = '这个操作已经执行过了';
      this.proposal = null;
    } else if (code === 'AI_PROPOSAL_EXPIRED') {
      this.confirmError = '确认超时（5 分钟），请重新让助手操作';
      this.proposal = null;
    } else if (code === 'AI_PROPOSAL_NOT_FOUND') {
      this.confirmError = '令牌无效，请重新让助手操作';
      this.proposal = null;
    } else if (code === 'AI_PROPOSAL_EXEC_FAILED') {
      // 业务规则拒绝（如进入阻塞却没填原因）：服务端不标记已消费，可改完条件后重试同一令牌
      this.confirmError = '执行被业务规则拒绝，请调整后重试';
    } else {
      this.confirmError = resp.error?.message ?? '确认失败，请重试';
    }
  }

  @Builder
  stepsTimeline() {
    if (this.agentSteps.length > 0) {
      Column({ space: Space.xs }) {
        Row({ space: Space.sm }) {
          Text('助手查了什么')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.textSecondary)
          Blank()
          Image($r('app.media.chevron_right'))
            .width(16)
            .height(16)
            .rotate({ angle: this.stepsExpanded ? 90 : 0 })
        }
        .width('100%')
        .onClick(() => {
          this.stepsExpanded = !this.stepsExpanded;
        })

        if (this.stepsExpanded) {
          ForEach(this.agentSteps, (step: AgentStep, index: number) => {
            Row({ space: Space.sm }) {
              Text(step.allowed ? '✓' : '✕')
                .fontSize(FontSize.caption)
                .fontColor(step.allowed ? StatusColor.done.fg : Color.textTertiary)
                .width(16)
              Text(step.allowed ? step.summary : `「${step.tool}」无权限访问`)
                .fontSize(FontSize.caption)
                .fontColor(step.allowed ? Color.textSecondary : Color.textTertiary)
                .lineHeight(18)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (step: AgentStep, index: number): string => `${index}-${step.tool}-${step.allowed}`)
        }

        Text(`共 ${this.agentSteps.length} 步 · 调用模型 ${this.agentCalls} 次`)
          .fontSize(FontSize.micro)
          .fontColor(Color.textTertiary)
          .width('100%')
      }
      .width('100%')
      .padding(Space.lg)
      .backgroundColor(Color.surface)
      .border({ width: 1, color: Color.border })
      .borderRadius(Radius.card)
    }
  }

  @Builder
  proposalCard() {
    if (this.proposal !== null || this.confirmedSummary.length > 0 || this.confirmError.length > 0) {
      Column({ space: Space.sm }) {
        if (this.proposal !== null) {
          Row({ space: Space.sm }) {
            Text(this.proposal.title)
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.textPrimary)
              .layoutWeight(1)
          }
          .width('100%')

          Text(this.proposal.target)
            .fontSize(FontSize.caption)
            .fontColor(Color.textSecondary)
            .width('100%')

          ForEach(this.proposal.diff, (line: AgentDiffLine, index: number) => {
            Row({ space: Space.sm }) {
              Text(diffFieldLabel(line.field))
                .fontSize(FontSize.caption)
                .fontColor(Color.textTertiary)
              Text(diffValueLabel(line.field, line.from))
                .fontSize(FontSize.caption)
                .fontColor(Color.textSecondary)
              Text('→')
                .fontSize(FontSize.caption)
                .fontColor(Color.textTertiary)
              Text(diffValueLabel(line.field, line.to))
                .fontSize(FontSize.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.primary)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (line: AgentDiffLine, index: number): string => `${index}-${line.field}`)

          if (this.confirmError.length > 0) {
            Text(this.confirmError)
              .fontSize(FontSize.caption)
              .fontColor(Color.danger)
              .width('100%')
          }

          Button(this.confirmLoading ? '确认中…' : `确认${this.proposal.title}`)
            .width('100%')
            .height(40)
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.onPrimary)
            .backgroundColor(Color.primary)
            .borderRadius(Radius.button)
            .enabled(!this.confirmLoading)
            .opacity(this.confirmLoading ? 0.7 : 1)
            .onClick(() => this.confirmProposal())
        } else {
          if (this.confirmedSummary.length > 0) {
            Text(this.confirmedSummary)
              .fontSize(FontSize.caption)
              .fontColor(StatusColor.done.fg)
              .width('100%')
          }
          if (this.confirmError.length > 0) {
            Text(this.confirmError)
              .fontSize(FontSize.caption)
              .fontColor(Color.danger)
              .width('100%')
          }
        }
      }
      .width('100%')
      .padding(Space.lg)
      .backgroundColor(Color.surface)
      .border({ width: 1, color: Color.border })
      .borderRadius(Radius.card)
    }
  }

  build() {
    Column() {
      Row() {
        Row({ space: 4 }) {
          Image($r('app.media.icon_chevron_left_primary'))
            .width(18)
            .height(18)
          Text('问一问')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.primary)
        }
        .height('100%')
        .onClick(() => backPage())

        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: Space.page, right: Space.page })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Color.surface)

      Divider()
        .strokeWidth(1)
        .color(Color.divider)

      Scroll() {
        Column({ space: Space.md }) {
          Column({ space: Space.md }) {
            TextArea({ placeholder: '例如：我作为部长有哪些权限？', text: this.question })
              .width('100%')
              .height(96)
              .fontSize(FontSize.body)
              .fontColor(Color.textPrimary)
              .placeholderColor(Color.textTertiary)
              .backgroundColor(Color.canvas)
              .borderRadius(Radius.input)
              .padding(Space.md)
              .onChange((value: string) => {
                this.question = value;
              })

            Row({ space: Space.sm }) {
              Toggle({ type: ToggleType.Switch, isOn: this.useAgent })
                .selectedColor(Color.primary)
                .onChange((on: boolean) => {
                  this.useAgent = on;
                })
              Column({ space: 2 }) {
                Text('查数据再回答（智能体）')
                  .fontSize(FontSize.body)
                  .fontColor(Color.textPrimary)
                Text('能先查任务/成员再回答，更慢')
                  .fontSize(FontSize.micro)
                  .fontColor(Color.textTertiary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Button(this.loading ? (this.useAgent ? '查询中…' : '提问中…') : (this.useAgent ? '查一查' : '提问'))
              .width('100%')
              .height(44)
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.onPrimary)
              .backgroundColor(Color.primary)
              .borderRadius(Radius.button)
              .shadow(Shadow.primary)
              .enabled(!this.loading)
              .opacity(this.loading ? 0.7 : 1)
              .onClick(() => this.submit())
          }
          .width('100%')
          .padding(Space.lg)
          .backgroundColor(Color.surface)
          .border({ width: 1, color: Color.border })
          .borderRadius(Radius.card)

          if (this.asked) {
            AiCard({
              source: this.source,
              loading: this.loading,
              errorMsg: this.errorMsg,
              body: this.answer,
              items: this.basisItems,
              note: this.note,
              onRetry: (): void => {
                this.submit();
              }
            })

            if (!this.loading && this.errorMsg.length === 0 && this.useAgent) {
              this.stepsTimeline()
              this.proposalCard()
            }
          }
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
