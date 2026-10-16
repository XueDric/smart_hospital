import {
  ApiConfig,
  ApiError,
  AppColor,
  AppRouter,
  AppSize,
  AppText,
  EmptyState,
  ErrorCode,
  InfoBanner,
  LoadingBlock,
  PageHeader,
  RouteName,
  asNumber,
  asString,
  formatEpoch,
  periodText
} from 'common-core';
import { DoctorRepository } from '../data/DoctorRepository';
import { EmrRecord, EmrSection, PastRecord, PrevisitSlot, PrevisitSummary } from '../model/DoctorModels';

/*
 * 七段锚点跳转时，List 项下标与"段序号"之间差的常量（预问诊卡 + 既往病历两个固定前缀块）。
 * 为什么用**固定**前缀项数、而不是"有内容才渲染"：`scrollToIndex` 收的是 List 的项下标，
 * 前缀项一旦随数据增减，锚点就会滚到别的段上 —— 这种错位在真机上极难被发现。
 */
const ANCHOR_PREFIX: number = 2;

/*
 * 从 409 的 `error.fields` 里读一个数字。
 * ⚠ 两处类型不一致要同时容忍：契约下发的是**数字**（updated_at / updated_by / record_id），
 *   而 `ApiError.fields` 声明为 Record<string, string>（HttpClient 只是未校验断言，数字原样透传）。
 *   而且整个 fields 可能**缺席**（首次 INSERT 撞唯一键、病历被删这两个分支都不带它）——
 *   所以只做尽力而为，取不到回 0，绝不假设它存在。
 */
function fieldsNumber(fields: Record<string, string> | undefined, key: string): number {
  if (fields === undefined) {
    return 0;
  }
  const raw = fields[key];
  if (raw === undefined) {
    return 0;
  }
  const parsed = Number.parseInt(`${raw}`, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

@ComponentV2
export struct EmrEditPage {
  private readonly repository: DoctorRepository = DoctorRepository.getInstance();
  // 七段锚点靠它定位（Scroll 没有"按项跳转"的能力，只有 List/Grid 的 scrollToIndex 有）。
  private readonly scroller: Scroller = new Scroller();

  @Local appointmentId: number = 0;
  @Local seq: number = 0;
  @Local patientId: number = 0;
  @Local visitDate: string = '';
  @Local period: string = '';
  @Local sections: EmrSection[] = [];
  @Local values: string[] = [];
  @Local locked: boolean = false;
  @Local loading: boolean = true;
  @Local saving: boolean = false;
  // 页面是否有未保存的输入改动；用于「提交锁定前先保存」、状态栏提示与离开保护。
  @Local dirty: boolean = false;
  // 服务端乐观锁（内容快照 + expected_updated_at）返回 409 EMR_CHANGED 时置位。
  @Local conflicted: boolean = false;
  // 已确认保存的版本（记录 updated_at，秒）；同时是下次保存的乐观锁基准。
  @Local recordUpdatedAt: number = 0;
  // 本次定稿落下的修订版本号；0 = 审计行没写上（病历已锁定成功，不是失败）。
  @Local revisionVersion: number = 0;
  @Local previsit: PrevisitSummary = new PrevisitSummary();
  @Local hasPrevisitSummary: boolean = false;
  @Local previsitRefSections: string[] = [];
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  // Mock 模式：只用来决定要不要显示"模拟他人修改"这个演示按钮（沿用登录页 mockMode 的做法）。
  @Local mockMode: boolean = false;
  // ── 工作台：既往病历 ──
  @Local pastRecords: PastRecord[] = [];
  @Local pastExpanded: number = -1;
  // ── 锚点当前高亮的段（<0 = 还没滚进七段区） ──
  @Local activeAnchor: number = -1;
  // ── 冲突核对（收到 EMR_CHANGED 后的人工确认） ──
  @Local showConflict: boolean = false;
  @Local conflictServerValues: string[] = [];
  @Local conflictAdopted: boolean[] = [];
  @Local conflictUpdatedAt: number = 0;
  @Local conflictUpdatedBy: number = 0;
  // ── 覆盖层 ──
  @Local showPreview: boolean = false;
  @Local showLeaveConfirm: boolean = false;
  // 确认框放行之后的去向：'' = 返回上一页；'history' = 去版本历史。
  @Local leaveTarget: string = '';

  aboutToAppear(): void {
    this.mockMode = ApiConfig.isMock();
    const params = AppRouter.getInstance().getParams();
    this.appointmentId = asNumber(params['appointmentId']);
    this.seq = asNumber(params['seq']);
    // 队列带过来的患者编号只是"省一次等待"；`load()` 里会用病历响应的 patient_id 校正。
    this.patientId = asNumber(params['patientId']);
    this.visitDate = asString(params['visitDate']);
    this.period = asString(params['period']);
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
      this.showConflict = false;
      // 重新从服务端读过之后，上一次冲突的服务端快照就成了过时消息，一并作废
      // （否则「核对冲突」会拿着旧快照让人对照，等于给出错的信息）。
      this.conflictServerValues = [];
      this.conflictAdopted = [];
      this.conflictUpdatedAt = 0;
      if (record.patientId > 0) {
        this.patientId = record.patientId;
      }
      // 既往病历要等 patientId 落定后再取，所以放在这里而不是与 load 并行。
      this.loadPastRecords();
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
    const next: string[] = [];
    for (const section of record.sections) {
      next.push(section.value);
    }
    this.values = next;
    this.locked = record.locked;
    this.recordUpdatedAt = record.updatedAt;
    this.revisionVersion = record.revisionVersion;
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

  /*
   * 既往已定稿病历。失败一律静默（列表为空即可）—— 这张卡片是"锦上添花"，
   * 让它弹错误反而会把医生的注意力从正在写的病历上拽走。
   * 尤其是 404 APPOINTMENT_NOT_FOUND：那是服务端刻意的隐私边界（"这位患者不在此医生名下"
   * 与"你没看过他"共用同一个码，避免枚举面），对客户端就是"没有既往"。
   */
  async loadPastRecords(): Promise<void> {
    if (this.patientId <= 0) {
      return;
    }
    try {
      const items = await this.repository.getPatientRecords(this.patientId, 5,
        this.appointmentId);
      this.pastRecords = this.newestFirst(items);
    } catch (error) {
      this.pastRecords = [];
    }
  }

  /*
   * 既往病历按**最近就诊在前**排。
   * 契约（§5.30.1）没有规定 `items` 的顺序，所以不能指望服务端的排列 ——
   * 直接按 `record.updated_at`（epoch 秒，恒定下发）倒序，既稳又不依赖字符串日期
   * （`visit_date` 在挂号单已被清理时是缺的，按它排会把那些条排到任意位置）。
   */
  private newestFirst(items: PastRecord[]): PastRecord[] {
    const sorted = items.slice();
    sorted.sort((left: PastRecord, right: PastRecord) => {
      return right.record.updatedAt - left.record.updatedAt;
    });
    return sorted;
  }

  // 统一错误出口。EMR_CHANGED / EMR_LOCKED 是两种**语义不同**的 409，必须分开处理。
  private handleError(error: Error): void {
    const apiError = ApiError.from(error);
    if (apiError.code === ErrorCode.EMR_CHANGED) {
      // 服务端按"内容快照 + expected_updated_at"做乐观锁；冲突时**保留医生输入**，
      // 再拉服务端当前版本供人工逐段核对 —— 绝不自动采用最新版本（那等于替医生签字）。
      this.conflicted = true;
      this.notice = '病历已被其他端修改：你的输入已保留，请逐段核对最新内容后再保存';
      this.noticeTone = 'error';
      this.loadConflict(apiError.fields);
      return;
    }
    if (apiError.code === ErrorCode.EMR_LOCKED) {
      // ⚠ 优先级高于 EMR_CHANGED（服务端先判 isLocked，再比 updated_at）。
      // 此时不是"重读版本再写就行" —— 医生自己没有解锁权限，得先去调解锁。
      this.conflicted = false;
      this.notice = '病历已定稿，需管理员解锁后才能修改';
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

  private visitLabel(): string {
    const parts: string[] = [];
    if (this.visitDate.length > 0) {
      parts.push(`${this.visitDate} ${periodText(this.period)}`);
    }
    if (this.seq > 0) {
      parts.push(`序号 ${this.seq}`);
    }
    return parts.join(' · ');
  }

  // ── 保存 / 定稿 ───────────────────────────────────────────────────────────

  /*
   * 保存草稿。带上 `recordUpdatedAt` 作为乐观锁基准（服务端在同一条 UPDATE 的 WHERE 里比）。
   * 幂等，且**不落修订版本**（版本只在 lock/reopen 落行），可以放心高频调用。
   */
  async saveDraft(): Promise<boolean> {
    if (this.saving) {
      return false;
    }
    this.saving = true;
    this.notice = '';
    try {
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap(), '',
        this.recordUpdatedAt);
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

  // 「提交锁定」不再直接提交：先过一遍预览（改进 2 的「提交前预览」），医生确认才落笔。
  openPreview(): void {
    if (this.saving || this.locked) {
      return;
    }
    this.showPreview = true;
  }

  async confirmLock(): Promise<void> {
    this.showPreview = false;
    if (this.saving || this.locked) {
      return;
    }
    this.saving = true;
    this.notice = '';
    try {
      // 提交锁定前先保存页面上的新修改，避免锁到旧内容。
      // 这里的乐观锁基准是"最近一次已确认的版本"，所以先保存 = 把自己的内容变成最新版，
      // 再锁定才不会锁到一个连自己都没存过的状态。
      if (this.dirty) {
        const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap(), '',
          this.recordUpdatedAt);
        this.applyRecord(record);
        this.dirty = false;
      }
      const lockedRecord = await this.repository.lockRecord(this.appointmentId);
      this.applyRecord(lockedRecord);
      this.conflicted = false;
      // revision_version = 0 只表示"审计行没写上"，病历**已经锁定成功** ——
      // 如实说成「版本号待补」，绝不提示重试（重试会走幂等分支自愈那一版）。
      this.notice = lockedRecord.revisionVersion > 0 ?
        `病历已提交锁定（修订 v${lockedRecord.revisionVersion}），锁定后不可修改` :
        '病历已提交锁定，锁定后不可修改（版本号待服务端补录）';
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
      const record = await this.repository.saveDraft(this.appointmentId, this.valuesMap(),
        sessionId, this.recordUpdatedAt);
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

  // ── 离开保护 ─────────────────────────────────────────────────────────────
  /*
   * 路由切换会销毁本页组件，未保存的输入直接消失。有改动时必须先问一句。
   * ⚠ 触发离开的**不止「返回」**：点「版本历史」同样是路由切换，一样会丢输入 ——
   *   所以这里用 leaveTarget 记住"要去哪"，两条出路共用同一个确认框。
   */
  private tryBack(): void {
    this.askBeforeLeave('');
  }

  private tryOpenHistory(): void {
    this.askBeforeLeave('history');
  }

  private askBeforeLeave(target: string): void {
    // 先**无条件**记下本次去向：否则上一次被取消的（比如"去版本历史"）会留在字段里，
    // 等下次已经不再 dirty、直接放行时，就会拿着旧去向跑到版本历史去而不是返回。
    this.leaveTarget = target;
    if (this.dirty && !this.locked) {
      this.showLeaveConfirm = true;
      return;
    }
    this.proceedAfterLeave();
  }

  // 确认框里选定之后的**唯一**出口（路由切换只在这里发生一次）。
  private proceedAfterLeave(): void {
    const target = this.leaveTarget;
    this.leaveTarget = '';
    this.showLeaveConfirm = false;
    if (target === 'history') {
      this.openHistory();
      return;
    }
    AppRouter.getInstance().back();
  }

  private discardAndLeave(): void {
    this.dirty = false;
    this.proceedAfterLeave();
  }

  private openHistory(): void {
    const params: Record<string, Object> = { 'appointmentId': this.appointmentId };
    AppRouter.getInstance().push(RouteName.DOCTOR_RECORD_HISTORY, params);
  }

  // Mock 专用的 409 演示入口（见 MockDoctorRepository.simulateConcurrentEdit）。
  async simulateConflict(): Promise<void> {
    await this.repository.simulateConcurrentEdit(this.appointmentId);
    this.notice = '已模拟他人修改：现在保存会触发 409，请输入内容后点「保存草稿」';
    this.noticeTone = 'info';
  }

  // 离开确认框里的「保存草稿后再继续」：存成功才走，失败就留在本页。
  async saveThenProceed(): Promise<void> {
    const saved = await this.saveDraft();
    if (saved) {
      this.proceedAfterLeave();
      return;
    }
    /*
     * 保存失败（最典型是 409 冲突）时**留在本页**：不把"没存上"变成"人已经走了"。
     * 同时必须把本确认框收起来 —— 冲突核对框在它下面，而它渲染在最上层，
     * 不收起来医生就点不到真正该处理的那个框（会以为界面卡住了）。
     */
    this.showLeaveConfirm = false;
  }

  private leavePrompt(): string {
    const tail = this.leaveTarget === 'history' ?
      '去版本历史会离开本页，这些改动同样会被丢弃。' : '离开本页会丢弃这些改动。';
    return `${tail}（路由切换会销毁页面，未保存的内容无法恢复）`;
  }

  // ── 冲突核对 ─────────────────────────────────────────────────────────────

  /*
   * 拉服务端当前版本，供医生逐段核对。
   * 先用 409 自带的 fields 兜底（可能缺席，也可能存成字符串），再拿完整病历覆盖成权威值 ——
   * 完整的病历响应既能给出"对面改成了什么"，也给出可靠的 updated_at。
   * 形参是 `fields` 而不是整个 ApiError：真正用到 409 body 的只有这两个数，
   * 传字段映射才能让「读不到最新版」时的重试（没有 409 可依托）复用同一条路径。
   */
  private async loadConflict(fields?: Record<string, string>): Promise<void> {
    // 只在 fields 真给了值时才覆盖：重试路径没有 409 可依托（fields 是 undefined），
    // 无条件赋值会把原始 409 已经告诉我们的版本号抹成 0，等于越重试知道得越少。
    const fieldUpdatedAt = fieldsNumber(fields, 'updated_at');
    if (fieldUpdatedAt > 0) {
      this.conflictUpdatedAt = fieldUpdatedAt;
      this.conflictUpdatedBy = fieldsNumber(fields, 'updated_by');
    }
    try {
      const record = await this.repository.getRecord(this.appointmentId);
      const serverValues: string[] = [];
      const adopted: boolean[] = [];
      for (const section of record.sections) {
        serverValues.push(section.value);
        adopted.push(false);
      }
      this.conflictServerValues = serverValues;
      this.conflictAdopted = adopted;
      if (record.updatedAt > 0) {
        this.conflictUpdatedAt = record.updatedAt;
        this.conflictUpdatedBy = record.updatedBy;
      }
      this.showConflict = true;
    } catch (error) {
      // 拉不到最新版也要让医生知道"有冲突"，但不假装知道对面改了什么。
      this.conflictServerValues = [];
      this.conflictAdopted = [];
      this.showConflict = true;
    }
  }

  // 能不能逐段核对，只取决于"有没有服务端那一版的内容"。
  // 不把版本号也算进来：拿到内容却缺 updated_at 时，让人看得见对照总比只给一句"读取失败"好
  // （基准刷不刷得新是另一件事，finishConflict 里单独把关）。
  private conflictResolvable(): boolean {
    return this.conflictServerValues.length > 0;
  }

  // 「用服务端这一段」：只覆盖医生显式点过的那一段。
  private adoptServerSection(index: number): void {
    const nextValues = this.values.slice();
    nextValues[index] = this.conflictServerValues[index] ?? '';
    this.values = nextValues;
    const nextAdopted = this.conflictAdopted.slice();
    nextAdopted[index] = true;
    this.conflictAdopted = nextAdopted;
    this.dirty = true;
  }

  private adoptAllServer(): void {
    const nextValues: string[] = [];
    const nextAdopted: boolean[] = [];
    for (let i = 0; i < this.conflictServerValues.length; i++) {
      nextValues.push(this.conflictServerValues[i] ?? '');
      nextAdopted.push(true);
    }
    this.values = nextValues;
    this.conflictAdopted = nextAdopted;
    this.dirty = true;
  }

  /*
   * 关闭冲突面板并把乐观锁基准**刷新到服务端当前版本**后再保存。
   * ⚠ 这一步容易被看成"取巧"，其实是必须的：判断"我的输入是否已经基于最新版"这件事
   *   已经由医生在上面逐段做完了（人工确认），此后保存就必须带服务端的 updated_at ——
   *   否则基准不刷新，医生核对完了照样永远 409。
   *   `keepMine` 只是把医生自己的内容再提交一次（即"覆盖服务端"），语义上是一次有意的写入。
   */
  private finishConflict(): void {
    /*
     * ⚠ 这一行是整段冲突流程的**成败所在**：乐观锁基准必须挪到服务端那一版。
     *   `recordUpdatedAt` 同时是"下次保存时回传给服务端的 expected_updated_at"，
     *   不挪的话，医生辛辛苦苦逐段核对完，再点保存还是拿旧基准去比 —— 照样 409，
     *   而且会反复弹这个核对框，变成一个出不去的循环。
     *   只有在确实读到了服务端版本（>0）时才挪：读失败时乱设基准等于伪造"我已基于最新版"。
     */
    if (this.conflictUpdatedAt > 0) {
      this.recordUpdatedAt = this.conflictUpdatedAt;
      this.notice = '已核对完：当前内容与最新版不再冲突，再保存即会覆盖服务端那一版（这是你刚确认过的）';
    } else {
      // 有对照内容、却没拿到服务端版本号 ⇒ 基准刷不了，再保存还是会 409。
      // 如实说，不假装"基准已更新"（那会让医生以为存得上，白填一遍）。
      this.notice = '已核对：但服务端版本号没取到，保存基准未更新 —— 需要离开本页重新进入再保存';
    }
    /*
     * 关框但**留着服务端快照**：这样医生可以随时按「核对冲突」再把同一份对照翻出来看，
     * 不必去人为再制造一次 409。快照在下一次真正重新读服务端（load）时才作废。
     */
    this.showConflict = false;
    this.conflicted = false;
    this.showPreview = false;
    this.noticeTone = 'info';
  }

  private hasConflictSnapshot(): boolean {
    return this.conflictServerValues.length > 0;
  }

  private async finishConflictAndSave(): Promise<void> {
    this.finishConflict();
    await this.saveDraft();
  }

  // 同一段里"我的"与"服务端"是否一致（只用于决定要不要渲染对比行，不参与任何判定）。
  private conflictDiffers(index: number): boolean {
    return (this.values[index] ?? '') !== (this.conflictServerValues[index] ?? '');
  }

  private conflictRowCount(): number {
    let count = 0;
    for (let i = 0; i < this.sections.length; i++) {
      if (this.conflictDiffers(i)) {
        count++;
      }
    }
    return count;
  }

  private conflictHeader(): string {
    const parts: string[] = [];
    if (this.conflictUpdatedBy > 0) {
      parts.push(`由 user #${this.conflictUpdatedBy}`);
    }
    if (this.conflictUpdatedAt > 0) {
      parts.push(formatEpoch(this.conflictUpdatedAt));
    }
    if (parts.length === 0) {
      return '服务端版本信息不可用';
    }
    return `服务端当前版本：${parts.join(' · ')} 修改`;
  }

  // ── 锚点 ─────────────────────────────────────────────────────────────────

  private jumpTo(index: number): void {
    this.scroller.scrollToIndex(ANCHOR_PREFIX + index, true, ScrollAlign.START);
  }

  private clampAnchor(start: number): number {
    const index = start - ANCHOR_PREFIX;
    if (index < 0) {
      return -1;
    }
    return index >= this.sections.length ? this.sections.length - 1 : index;
  }

  // ── 预问诊采纳 ───────────────────────────────────────────────────────────

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
    const nextValues = this.values.slice();
    nextValues[index] = current.length === 0 ? piece : `${current}\n${piece}`;
    this.values = nextValues;
    this.dirty = true;
    this.conflicted = false;
    this.notice = `已把「${slot.label}」采纳到病历（追加，未覆盖）`;
    this.noticeTone = 'success';
  }

  // ── 既往病历 ─────────────────────────────────────────────────────────────

  private sectionValueOf(record: EmrRecord, key: string): string {
    for (const section of record.sections) {
      if (section.key === key) {
        return section.value;
      }
    }
    return '';
  }

  private pastSummary(past: PastRecord): string {
    const diagnosis = this.sectionValueOf(past.record, 'diagnosis');
    const chief = this.sectionValueOf(past.record, 'chief_complaint');
    if (diagnosis.length > 0) {
      return `诊断：${diagnosis}`;
    }
    if (chief.length > 0) {
      return `主诉：${chief}`;
    }
    return '（无诊断与主诉记录）';
  }

  private previewText(index: number): string {
    const value = this.values[index] ?? '';
    return value.length > 0 ? value : '（未填写）';
  }

  private previewMissingRequired(): number {
    let count = 0;
    for (let i = 0; i < this.sections.length; i++) {
      if (this.sections[i].requiredToLock && (this.values[i] ?? '').trim().length === 0) {
        count++;
      }
    }
    return count;
  }

  build() {
    Stack() {
      this.mainContent()
      if (this.showPreview) {
        this.previewOverlay()
      }
      if (this.showConflict) {
        this.conflictOverlay()
      }
      if (this.showLeaveConfirm) {
        this.leaveOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  mainContent() {
    Column() {
      PageHeader({
        title: `电子病历 · 序号 ${this.seq}`,
        showBack: true,
        // 有未保存改动时不能直接走人：路由切换会销毁本页组件，输入就没了。
        interceptBack: true,
        onBack: () => this.tryBack()
      })

      /*
       * 患者栏。⚠ 这里**只有患者编号**：医生端目前没有任何端点下发患者姓名/性别 ——
       * 队列项、病历、预问诊摘要、既往病历一律只回 patient_id（后端有意不把姓名放进出参，
       * 见 docs/FRONTEND-INTEGRATION.md §5.30.1 与验收脚本对 patient_name 的禁用）。
       * TODO(后端补出参字段后): 姓名/性别接入此栏，编号退为副标题。
       */
      Row() {
        Text(`患者 #${this.patientId}`)
          .fontSize(AppText.SUBHEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .layoutWeight(1)
        Text(this.visitLabel())
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(this.statusText())
          .fontSize(AppText.CAPTION)
          .fontColor(this.conflicted || this.dirty ? AppColor.WARNING : AppColor.TEXT_SECONDARY)
          .layoutWeight(1)
        if (this.revisionVersion > 0) {
          Text(`修订 v${this.revisionVersion}`)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.INFO)
            .margin({ right: AppSize.GAP })
        }
        /*
         * 「核对冲突」而不是「重新加载」：重新加载会 applyRecord 覆盖掉医生的输入 ——
         * 那正是"你的输入已保留"承诺的反面。这里只是把服务端快照的对照面板再打开一次，
         * 一个字都不碰本地内容。
         */
        if (this.hasConflictSnapshot()) {
          Button('核对冲突')
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.DANGER)
            .backgroundColor(AppColor.DANGER_SOFT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ right: AppSize.GAP })
            .onClick(() => {
              this.showConflict = true;
            })
        }
        Button('版本历史')
          .height(AppSize.TOUCH_MIN)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.PRIMARY)
          .backgroundColor(AppColor.PRIMARY_SOFT)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .enabled(!this.loading)
          .onClick(() => this.tryOpenHistory())
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      .alignItems(VerticalAlign.Center)

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      this.anchorBar()

      if (this.loading) {
        LoadingBlock()
      } else if (this.sections.length === 0) {
        EmptyState({ title: '暂无病历段落', description: '服务端未返回七段结构' })
      } else {
        List({ scroller: this.scroller }) {
          ListItem() {
            this.previsitBlock()
          }
          ListItem() {
            this.pastBlock()
          }
          ForEach(this.sections, (section: EmrSection, index: number) => {
            ListItem() {
              this.sectionCard(section, index)
            }
          }, (section: EmrSection) => `emr-${section.key}`)
          ListItem() {
            this.footerBlock()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
        .onScrollIndex((start: number) => {
          this.activeAnchor = this.clampAnchor(start);
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 })
  }

  @Builder
  anchorBar() {
    if (!this.loading && this.sections.length > 0) {
      Scroll() {
        Row() {
          ForEach(this.sections, (section: EmrSection, index: number) => {
            Text(section.label)
              .fontSize(AppText.CAPTION)
              .fontColor(this.activeAnchor === index ? AppColor.SURFACE : AppColor.PRIMARY_DARK)
              .backgroundColor(this.activeAnchor === index ? AppColor.PRIMARY : AppColor.PRIMARY_SOFT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .constraintSize({ minHeight: AppSize.TOUCH_MIN })
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8 })
              .onClick(() => this.jumpTo(index))
          }, (section: EmrSection) => `anchor-${section.key}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
    }
  }

  @Builder
  previsitBlock() {
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
              .height(AppSize.TOUCH_MIN)
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
        }, (slot: PrevisitSlot) => `slot-${slot.key}`)

        if (!this.locked && this.previsit.sessionId.length > 0) {
          InfoBanner({
            message: '可由预问诊单预填（use_intake_session，仅首次）',
            tone: 'info',
            actionText: this.saving ? '预填中…' : '一键预填',
            onAction: () => this.prefill()
          })
            .margin({ top: AppSize.GAP })
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
      .margin({ bottom: AppSize.GAP })
    }
  }

  @Builder
  pastBlock() {
    if (this.pastRecords.length > 0) {
      Column() {
        Text(`既往病历（该患者已定稿 ${this.pastRecords.length} 份）`)
          .fontSize(AppText.SUBHEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')

        ForEach(this.pastRecords, (past: PastRecord, index: number) => {
          Column() {
            Row() {
              Column() {
                Text(`${past.visitDate} ${periodText(past.period)}`)
                  .fontSize(AppText.BODY)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.TEXT)
                Text(this.pastContext(past))
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(this.pastExpanded === index ? '收起' : '展开')
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.PRIMARY_DARK)
                .constraintSize({ minHeight: AppSize.TOUCH_MIN })
                .padding({ left: 12, right: 4, top: 8, bottom: 8 })
                .onClick(() => {
                  this.pastExpanded = this.pastExpanded === index ? -1 : index;
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(this.pastSummary(past))
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT)
              .width('100%')
              .margin({ top: 6 })

            if (this.pastExpanded === index) {
              ForEach(past.record.sections, (section: EmrSection) => {
                if (section.value.length > 0) {
                  Column() {
                    Text(section.label)
                      .fontSize(AppText.MICRO)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .width('100%')
                    Text(section.value)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT)
                      .width('100%')
                      .margin({ top: 2 })
                  }
                  .width('100%')
                  .margin({ top: 8 })
                }
              }, (section: EmrSection) => `past-${index}-${section.key}`)
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor(AppColor.SURFACE_ALT)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: AppSize.GAP })
        }, (past: PastRecord) => `past-${past.record.appointmentId}`)
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
      .margin({ bottom: AppSize.GAP })
    }
  }

  private pastContext(past: PastRecord): string {
    const parts: string[] = [];
    if (past.departmentName.length > 0) {
      parts.push(past.departmentName);
    }
    if (past.doctorName.length > 0) {
      parts.push(past.doctorTitle.length > 0 ? `${past.doctorName} ${past.doctorTitle}` :
        past.doctorName);
    }
    return parts.length > 0 ? parts.join(' · ') : '就诊科室与医生未下发';
  }

  @Builder
  sectionCard(section: EmrSection, index: number) {
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
          const nextValues = this.values.slice();
          nextValues[index] = value;
          this.values = nextValues;
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
  }

  @Builder
  footerBlock() {
    Column() {
      if (this.locked) {
        InfoBanner({
          message: '已提交锁定，仅管理员可解锁重写；医生不可修改。解锁与理由归管理员，医生端只读版本历史。',
          tone: 'warning'
        })

        Button(this.saving ? '提交中…' : '完成就诊')
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.SURFACE)
          .backgroundColor(AppColor.PRIMARY)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .enabled(!this.saving)
          .margin({ top: AppSize.GAP })
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
          // 不直接锁定：先过预览（改进 2 的「提交前预览」）。
          Button('提交锁定')
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .enabled(!this.saving)
            .margin({ left: AppSize.GAP })
            .onClick(() => this.openPreview())
        }
        .width('100%')
        .margin({ top: 4 })

        Text('锁定后不可修改；解锁重写为管理员动作，且必须填写理由')
          .width('100%')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.WARNING)
          .margin({ top: AppSize.GAP })

        /*
         * 演示用：Mock 下没有第二个写入者，409 EMR_CHANGED 的核对流程永远走不到。
         * 只在 Mock 模式显示 —— 真机上不该有这个按钮（用户也绝不该看到"模拟修改"）。
         */
        if (this.mockMode) {
          Button('模拟他人修改（仅 Mock 演示）')
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.GAP })
            .onClick(() => this.simulateConflict())
        }
      }
    }
    .width('100%')
    .padding({ bottom: 24 })
  }

  // ── 覆盖层 ───────────────────────────────────────────────────────────────

  @Builder
  previewOverlay() {
    Stack() {
      // 用 Text('') 当背板：叶子组件无需子节点即可铺满，且避免硬编码色值
      // （设计规范禁止硬编码颜色，所以走 token + opacity）。
      Text('')
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.TEXT)
        .opacity(0.45)
        .onClick(() => {
          this.showPreview = false;
        })

      Column() {
        Text('提交前预览')
          .fontSize(AppText.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')
        Text(this.previewMissingRequired() > 0 ?
          `还有 ${this.previewMissingRequired()} 个必填段未填，提交会被服务端拒绝` :
          '七段必填已齐，提交后不可修改（仅管理员可解锁重写）')
          .fontSize(AppText.CAPTION)
          .fontColor(this.previewMissingRequired() > 0 ? AppColor.DANGER : AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 6 })

        Scroll() {
          Column() {
            ForEach(this.sections, (section: EmrSection, index: number) => {
              Column() {
                Text(section.requiredToLock ? `${section.label}（必填）` : section.label)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .width('100%')
                Text(this.previewText(index))
                  .fontSize(AppText.BODY)
                  .fontColor((this.values[index] ?? '').length > 0 ? AppColor.TEXT : AppColor.DANGER)
                  .width('100%')
                  .margin({ top: 4 })
              }
              .width('100%')
              .padding({ top: AppSize.GAP, bottom: AppSize.GAP })
              .border({ width: { bottom: 1 }, color: AppColor.BORDER })
            }, (section: EmrSection) => `preview-${section.key}`)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: AppSize.GAP })

        Row() {
          Button('返回修改')
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.PRIMARY)
            .backgroundColor(AppColor.PRIMARY_SOFT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onClick(() => {
              this.showPreview = false;
            })
          Button(this.saving ? '提交中…' : '确认提交锁定')
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .enabled(!this.saving)
            .margin({ left: AppSize.GAP })
            .onClick(() => this.confirmLock())
        }
        .width('100%')
        .margin({ top: AppSize.GAP })
      }
      .width('90%')
      .height('80%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  @Builder
  conflictOverlay() {
    Stack() {
      // 冲突核对**不可点遮罩关闭**：这是"必须做一次人工确认"的地方，
      // 随手点掉就等于把冲突忘了，下次保存还会 409。
      Text('')
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.TEXT)
        .opacity(0.45)

      Column() {
        Text('病历已被其他端修改')
          .fontSize(AppText.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.DANGER)
          .width('100%')
        Text(this.conflictHeader())
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 6 })
        Text(this.conflictResolvable() ?
          `共 ${this.conflictRowCount()} 段与你的输入不同。逐段选择要保留的版本 —— 不做任何选择不会自动采用服务端内容。` :
          '服务端最新版本读取失败，请重试后再核对（你的输入已保留）。')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 6 })

        Scroll() {
          Column() {
            ForEach(this.sections, (section: EmrSection, index: number) => {
              if (this.conflictResolvable() && this.conflictDiffers(index)) {
                Column() {
                  Row() {
                    Text(section.label)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                      .layoutWeight(1)
                    if (this.conflictAdopted[index]) {
                      Text('已采用服务端')
                        .fontSize(AppText.CAPTION)
                        .fontColor(AppColor.SUCCESS)
                    } else {
                      Button('用服务端')
                        .height(AppSize.TOUCH_MIN)
                        .fontSize(AppText.CAPTION)
                        .fontColor(AppColor.PRIMARY)
                        .backgroundColor(AppColor.PRIMARY_SOFT)
                        .borderRadius(AppSize.CONTROL_RADIUS)
                        .enabled(!this.saving)
                        .onClick(() => this.adoptServerSection(index))
                    }
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Text('我的：')
                    .fontSize(AppText.MICRO)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .width('100%')
                    .margin({ top: 6 })
                  Text(this.previewText(index))
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT)
                    .width('100%')

                  Text('服务端：')
                    .fontSize(AppText.MICRO)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .width('100%')
                    .margin({ top: 6 })
                  Text((this.conflictServerValues[index] ?? '').length > 0 ?
                    (this.conflictServerValues[index] ?? '') : '（服务端该段为空）')
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT)
                    .width('100%')
                }
                .width('100%')
                .padding({ top: AppSize.GAP, bottom: AppSize.GAP })
                .border({ width: { bottom: 1 }, color: AppColor.BORDER })
              }
            }, (section: EmrSection) => `conflict-${section.key}`)

            if (this.conflictResolvable() && this.conflictRowCount() === 0) {
              Text('本页七段与服务端当前版本一致，可直接保存。')
                .fontSize(AppText.BODY)
                .fontColor(AppColor.TEXT_SECONDARY)
                .width('100%')
                .margin({ top: AppSize.GAP })
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: AppSize.GAP })

        if (this.conflictResolvable()) {
          Button('全部采用服务端')
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.PRIMARY)
            .backgroundColor(AppColor.PRIMARY_SOFT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .enabled(!this.saving)
            .margin({ top: AppSize.GAP })
            .onClick(() => this.adoptAllServer())

          Button(this.saving ? '保存中…' : '保留我的输入并保存（覆盖服务端）')
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .enabled(!this.saving)
            .margin({ top: AppSize.GAP })
            .onClick(() => this.finishConflictAndSave())

          Button('已核对，先不保存')
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.TEXT_SECONDARY)
            .backgroundColor(Color.Transparent)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.GAP })
            .onClick(() => this.finishConflict())
        } else {
          Button('重试读取服务端最新版')
            .width('100%')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.GAP })
            .onClick(() => this.loadConflict())
        }
      }
      .width('90%')
      .height('80%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  @Builder
  leaveOverlay() {
    Stack() {
      Text('')
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.TEXT)
        .opacity(0.45)
        .onClick(() => {
          this.showLeaveConfirm = false;
        })

      Column() {
        Text('有未保存的改动')
          .fontSize(AppText.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')
        Text(this.leavePrompt())
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 6 })

        Button(this.saving ? '保存中…' : '保存草稿后再继续')
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .fontColor(AppColor.SURFACE)
          .backgroundColor(AppColor.PRIMARY)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .enabled(!this.saving)
          .margin({ top: AppSize.GAP })
          .onClick(() => this.saveThenProceed())

        Button('放弃改动并继续')
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .fontColor(AppColor.DANGER)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: AppColor.DANGER })
          .borderRadius(AppSize.CONTROL_RADIUS)
          .margin({ top: AppSize.GAP })
          .onClick(() => this.discardAndLeave())

        Button('继续编辑')
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .fontColor(AppColor.TEXT_SECONDARY)
          .backgroundColor(Color.Transparent)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .margin({ top: AppSize.GAP })
          .onClick(() => {
            this.showLeaveConfirm = false;
          })
      }
      .width('90%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
