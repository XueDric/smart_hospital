// 负责人：彭翌菲
// 展示个人资料、角色权限、管理入口和离线队列状态，
// 同时提供修改密码、同步待处理请求和退出登录等设置功能。

/**
 * 我的：身份、权限、管理入口、改密码与 Outbox。
 */
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { AuthApi, ChangePasswordRequest, MemberSelf, UserPermissions } from '../api/AuthApi';
import { HttpClient } from '../api/HttpClient';
import { BASE_URL } from '../config/Env';
import { FormField } from '../components/FormField';
import {
  AvatarBorderWidth,
  Color,
  FontSize,
  Radius,
  Shadow,
  Space,
  StatusColor,
  roleAvatarBorder,
  roleAvatarColor,
  roleAvatarFg,
  roleAvatarGradient,
} from '../core/Theme';
import { can } from '../store/PermissionStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { OutboxItem, OutboxStore } from '../store/OutboxStore';
import { OutboxSync, OutboxSyncResult } from '../store/OutboxSync';
import { SessionStore } from '../store/SessionStore';
import { ServerConfigStore } from '../store/ServerConfigStore';
import { pushTo, replaceTo } from '../utils/RouterUtils';

interface PermissionDisplay {
  desc: string;
  ok: boolean;
  showIcon: boolean;
}

@Component
export struct ProfilePage {
  @Prop @Watch('onRefreshSignal') refreshSignal: number = 0;
  @State user: MemberSelf | null = null;
  @State permissions: UserPermissions | null = null;
  @State permissionExpanded: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State hoveredEntry: string = '';

  @State outboxCount: number = 0;
  @State outboxItems: OutboxItem[] = [];
  @State showOutbox: boolean = false;
  @State syncingOutbox: boolean = false;

  @State showPasswordSheet: boolean = false;
  @State oldPassword: string = '';
  @State newPassword: string = '';
  @State confirmPassword: string = '';
  @State oldPasswordError: string = '';
  @State newPasswordError: string = '';
  @State confirmPasswordError: string = '';
  @State passwordError: string = '';
  @State changingPassword: boolean = false;

  @State showServerSheet: boolean = false;
  @State serverUrl: string = '';
  @State serverUrlError: string = '';
  @State currentBaseUrl: string = '';
  @State savingServerUrl: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private permissionStore: PermissionStore = PermissionStore.getInstance();
  private outboxStore: OutboxStore = OutboxStore.getInstance();

  aboutToAppear(): void {
    this.currentBaseUrl = HttpClient.getInstance().getBaseUrl();
    this.refreshPage();
  }

  onRefreshSignal(): void {
    this.refreshPage();
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('我的')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#101828')

          Blank()

          Image($r('app.media.bit_logo'))
            .width(32)
            .height(32)
            .objectFit(ImageFit.Contain)
        }
        .width('100%')
        .height(52)
        .padding({ left: Space.page, right: Space.page })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#FFFFFF')

        Divider()
          .strokeWidth(1)
          .color('#F3F4F6')

        Scroll() {
          Column({ space: 12 }) {
            this.profileCard()

            if (this.errorMsg.length > 0) {
              Text(this.errorMsg)
                .width('100%')
                .fontSize(FontSize.caption)
                .fontColor('#FB2C36')
                .textAlign(TextAlign.Center)
            }

            this.permissionCard()
            this.managementCard()
            this.settingsCard()

            Button('退出登录')
              .width('100%')
              .height(46)
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FB2C36')
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#FFC9C9' })
              .borderRadius(12)
              .onClick(() => this.confirmLogout())
          }
          .width('100%')
          .padding({ left: Space.page, right: Space.page, top: 12, bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F9FAFB')

      if (this.showPasswordSheet) {
        this.passwordSheet()
      }
      if (this.showOutbox) {
        this.outboxSheet()
      }
      if (this.showServerSheet) {
        this.serverSheet()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  profileCard() {
    Row({ space: 14 }) {
      Text(this.profileInitial())
        .width(56)
        .height(56)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(roleAvatarFg(this.user?.role))
        .textAlign(TextAlign.Center)
        .borderRadius(28)
        .linearGradient({
          angle: 180,
          colors: [[roleAvatarColor(this.user?.role), 0.0], [roleAvatarGradient(this.user?.role), 1.0]],
        })
        .border({
          width: AvatarBorderWidth.normal,
          color: roleAvatarBorder(this.user?.role),
        })

      Column({ space: 4 }) {
        Text(this.user?.name ?? '未登录')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')

        Text(this.maskPhone(this.user?.phone ?? ''))
          .fontSize(FontSize.body)
          .fontFamily('Inter')
          .fontFeature('"tnum" 1')
          .fontColor('#99A1AF')

        Row({ space: 6 }) {
          Text(this.user?.dept?.name ?? '未分配')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor('#008236')
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
            .backgroundColor('#DCFCE7')
            .borderRadius(Radius.pill)

          Text(this.roleLabel(this.user?.role ?? ''))
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4A5565')
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
            .backgroundColor('#F3F4F6')
            .borderRadius(Radius.pill)
        }
        .margin({ top: 1 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
  }

  @Builder
  permissionCard() {
    Column() {
      Row() {
        Text('我的权限')
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor('#101828')
        Blank()
        Image($r('app.media.chevron_right'))
          .width(16)
          .height(16)
          .rotate({ angle: this.permissionExpanded ? 90 : 0 })
      }
      .width('100%')
      .onClick(() => {
        this.permissionExpanded = !this.permissionExpanded;
      })

      if (this.permissionExpanded) {
        Divider()
          .strokeWidth(1)
          .color('#F9FAFB')
          .margin({ top: 10 })

        ForEach(this.permissionRows(), (item: PermissionDisplay, index: number) => {
          if (index > 0) {
            Divider()
              .strokeWidth(1)
              .color('#F9FAFB')
          }

          Row({ space: 8 }) {
            Text(item.desc)
              .layoutWeight(1)
              .fontSize(FontSize.body)
              .fontColor('#4A5565')

            if (item.showIcon) {
              Image(item.ok ? $r('app.media.icon_check') : $r('app.media.icon_cross'))
                .width(16)
                .height(16)
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }, (item: PermissionDisplay): string => item.desc)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
  }

  @Builder
  managementCard() {
    if (this.canManageMembers() || this.canOpenManage()) {
      Column() {
        if (this.canApprovePending()) {
          this.entryRow('待分配审批', 'pages/ApprovePage', 'approve')
        }

        if (this.canManageMembers() && this.canOpenManage()) {
          Divider()
            .strokeWidth(1)
            .color('#F9FAFB')
        }

        if (this.canOpenManage()) {
          this.entryRow('管理 · 部门 / 口令 / 链接 / 成员', 'pages/AdminPage', 'manage')
        }
      }
      .width('100%')
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#F3F4F6' })
      .borderRadius(12)
      .shadow(Shadow.L1)
      .clip(true)
    }
  }

  @Builder
  settingsCard() {
    Column() {
      Row() {
        Text('改密码')
          .fontSize(FontSize.body)
          .fontColor('#101828')
        Blank()
        Image($r('app.media.chevron_right'))
          .width(16)
          .height(16)
      }
      .width('100%')
      .height(44)
      .padding({ left: Space.page, right: Space.page })
      .backgroundColor(this.hoveredEntry === 'password' ? '#F9FAFB' : '#00000000')
      .onHover((isHover: boolean) => {
        if (isHover) {
          this.hoveredEntry = 'password';
        } else if (this.hoveredEntry === 'password') {
          this.hoveredEntry = '';
        }
      })
      .onClick(() => this.openPasswordSheet())

      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')

      this.entryRow('问一问', 'pages/AskPage', 'ask')

      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')

      Row() {
        Text('服务器地址（调试）')
          .layoutWeight(1)
          .fontSize(FontSize.body)
          .fontColor('#101828')

        Text(this.currentBaseUrl.length > 0 ? this.currentBaseUrl : '使用默认地址')
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor('#99A1AF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 180 })

        Image($r('app.media.chevron_right'))
          .width(16)
          .height(16)
          .margin({ left: 6 })
      }
      .width('100%')
      .height(44)
      .padding({ left: Space.page, right: Space.page })
      .backgroundColor(this.hoveredEntry === 'server' ? '#F9FAFB' : '#00000000')
      .onHover((isHover: boolean) => {
        if (isHover) {
          this.hoveredEntry = 'server';
        } else if (this.hoveredEntry === 'server') {
          this.hoveredEntry = '';
        }
      })
      .onClick(() => this.openServerSheet())

      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')

      Row() {
        Text('待同步的更改（Outbox）')
          .layoutWeight(1)
          .fontSize(FontSize.body)
          .fontColor('#101828')

        Text(this.outboxCount === 0 ? '已同步' : `${this.outboxCount} 条排队中`)
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.outboxCount > 0 ? '#FE9A00' : '#99A1AF')

        Image($r('app.media.chevron_right'))
          .width(16)
          .height(16)
          .margin({ left: 6 })
      }
      .width('100%')
      .height(44)
      .padding({ left: Space.page, right: Space.page })
      .backgroundColor(this.hoveredEntry === 'outbox' ? '#F9FAFB' : '#00000000')
      .onHover((isHover: boolean) => {
        if (isHover) {
          this.hoveredEntry = 'outbox';
        } else if (this.hoveredEntry === 'outbox') {
          this.hoveredEntry = '';
        }
      })
      .onClick(() => this.openOutbox())
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
    .clip(true)
  }

  @Builder
  entryRow(title: string, path: string, hoverKey: string) {
    Row() {
      Text(title)
        .layoutWeight(1)
        .fontSize(FontSize.body)
        .fontColor('#101828')

      Image($r('app.media.chevron_right'))
        .width(16)
        .height(16)
    }
    .width('100%')
    .height(44)
    .padding({ left: Space.page, right: Space.page })
    .backgroundColor(this.hoveredEntry === hoverKey ? '#F9FAFB' : '#00000000')
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.hoveredEntry = hoverKey;
      } else if (this.hoveredEntry === hoverKey) {
        this.hoveredEntry = '';
      }
    })
    .onClick(() => pushTo(path))
  }

  @Builder
  passwordSheet() {
    Column() {
      Column({ space: 10 }) {
        Row()
          .width(36)
          .height(4)
          .backgroundColor('#F3F4F6')
          .borderRadius(2)

        Row() {
          Text('改密码')
            .fontSize(FontSize.title)
            .fontWeight(600)
            .fontColor('#101828')
          Blank()
          Text('关闭')
            .fontSize(FontSize.caption)
            .fontColor('#99A1AF')
            .onClick(() => {
              if (!this.changingPassword) this.showPasswordSheet = false;
            })
        }
        .width('100%')

        Text('改密后你当前这台设备不受影响，但其它设备的登录会立即失效。')
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#4A5565')

        FormField({
          fieldLabel: '当前密码',
          placeholder: '请输入当前密码',
          inputValue: $oldPassword,
          errorText: this.oldPasswordError,
          isPassword: true,
          maxLength: 32
        })
        FormField({
          fieldLabel: '新密码',
          placeholder: '请输入新密码',
          inputValue: $newPassword,
          errorText: this.newPasswordError,
          hint: '长度 8–32 字节，且仅含数字、英文或符号。',
          isPassword: true,
          maxLength: 32
        })
        FormField({
          fieldLabel: '再次输入新密码',
          placeholder: '请再次输入新密码',
          inputValue: $confirmPassword,
          errorText: this.confirmPasswordError,
          isPassword: true,
          maxLength: 32
        })

        if (this.passwordError.length > 0) {
          Text(this.passwordError)
            .width('100%')
            .fontSize(FontSize.caption)
            .fontColor('#FB2C36')
        }

        Text('忘记密码请找会长或副会长在管理页为你重置。')
          .width('100%')
          .fontSize(FontSize.micro)
          .fontColor('#99A1AF')

        Button(this.changingPassword ? '提交中…' : '确认修改')
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Color.onPrimary)
          .backgroundColor('#2563EB')
          .borderRadius(12)
          .shadow(Shadow.primary)
          .enabled(!this.changingPassword)
          .onClick(() => this.changePassword())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: Radius.sheet, topRight: Radius.sheet })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 80 })
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.End)
  }

  @Builder
  outboxSheet() {
    Column() {
      Column({ space: 10 }) {
        Row()
          .width(36)
          .height(4)
          .backgroundColor('#F3F4F6')
          .borderRadius(2)

        Row() {
          Text(`待同步的更改（${this.outboxCount}）`)
            .fontSize(FontSize.title)
            .fontWeight(600)
            .fontColor('#101828')
          Blank()
          Text('关闭')
            .fontSize(FontSize.caption)
            .fontColor('#99A1AF')
            .onClick(() => {
              this.showOutbox = false;
            })
        }
        .width('100%')

        if (this.outboxItems.length === 0) {
          Text('没有待同步的更改。')
            .fontSize(FontSize.body)
            .fontColor('#99A1AF')
            .padding({ top: 24, bottom: 24 })
        } else {
          List({ space: 8 }) {
            ForEach(this.outboxItems, (item: OutboxItem) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row() {
                    Text(item.label)
                      .fontSize(FontSize.body)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#101828')
                    Blank()
                    Text(`${item.method} ${item.path}`)
                      .fontSize(FontSize.micro)
                      .fontColor('#99A1AF')
                  }
                  .width('100%')
                  if (item.last_error.length > 0) {
                    Text(item.last_error)
                      .width('100%')
                      .fontSize(FontSize.micro)
                      .fontColor('#FB2C36')
                  }
                  Row() {
                    Blank()
                    Text('丢弃')
                      .fontSize(FontSize.caption)
                      .fontColor('#FB2C36')
                      .onClick(() => this.discardOne(item.id))
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(12)
                .backgroundColor('#F9FAFB')
                .borderRadius(Radius.input)
              }
            }, (item: OutboxItem): string => item.id)
          }
          .width('100%')
          .height(280)

          Row({ space: 10 }) {
            Button('丢弃全部')
              .layoutWeight(1)
              .height(46)
              .fontSize(FontSize.body)
              .fontColor('#FB2C36')
              .backgroundColor('#FFE2E2')
              .borderRadius(12)
              .enabled(!this.syncingOutbox)
              .onClick(() => this.discardAll())

            Button(this.syncingOutbox ? '同步中…' : '立即同步')
              .layoutWeight(1)
              .height(46)
              .fontSize(FontSize.body)
              .fontColor(Color.onPrimary)
              .backgroundColor('#2563EB')
              .borderRadius(12)
              .enabled(!this.syncingOutbox)
              .onClick(() => this.syncOutbox())
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: Radius.sheet, topRight: Radius.sheet })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 80 })
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.End)
  }

  // 杨睿加：服务器地址调试弹窗，联调时直接改后端 IP 无需重新编译
  @Builder
  serverSheet() {
    Column() {
      Column({ space: 10 }) {
        Row()
          .width(36)
          .height(4)
          .backgroundColor('#F3F4F6')
          .borderRadius(2)

        Row() {
          Text('服务器地址（调试）')
            .fontSize(FontSize.title)
            .fontWeight(600)
            .fontColor('#101828')
          Blank()
          Text('关闭')
            .fontSize(FontSize.caption)
            .fontColor('#99A1AF')
            .onClick(() => {
              if (!this.savingServerUrl) this.showServerSheet = false;
            })
        }
        .width('100%')

        Text('仅用于联调：填写后端服务的完整地址（含 /api/v1），保存后立即生效，重启后仍然有效。')
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#4A5565')

        FormField({
          fieldLabel: '服务器地址',
          placeholder: BASE_URL,
          inputValue: $serverUrl,
          errorText: this.serverUrlError,
          hint: `当前：${this.currentBaseUrl.length > 0 ? this.currentBaseUrl : BASE_URL}`,
          maxLength: 256
        })

        if (this.serverUrlError.length > 0) {
          Text(this.serverUrlError)
            .width('100%')
            .fontSize(FontSize.caption)
            .fontColor('#FB2C36')
        }

        Row({ space: 10 }) {
          Button('恢复默认')
            .layoutWeight(1)
            .height(46)
            .fontSize(FontSize.body)
            .fontColor('#4A5565')
            .backgroundColor('#F3F4F6')
            .borderRadius(12)
            .enabled(!this.savingServerUrl)
            .onClick(() => this.resetServerUrl())

          Button(this.savingServerUrl ? '保存中…' : '保存并生效')
            .layoutWeight(1)
            .height(46)
            .fontSize(FontSize.body)
            .fontColor(Color.onPrimary)
            .backgroundColor('#2563EB')
            .borderRadius(12)
            .enabled(!this.savingServerUrl)
            .onClick(() => this.saveServerUrl())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: Radius.sheet, topRight: Radius.sheet })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 80 })
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.End)
  }

  private async refreshPage(): Promise<void> {
    this.loading = true;
    const response = await this.authApi.me();
    if (response.ok && response.data !== undefined) {
      const update: UpdateData = {
        user: response.data.member,
        permissions: response.data.permissions,
      };
      this.permissionStore.update(update);
      this.user = response.data.member;
      this.permissions = response.data.permissions;
      this.errorMsg = '';
    } else {
      this.errorMsg = response.error?.message ?? '加载失败，请重试';
    }
    await this.loadOutbox();
    this.loading = false;
  }

  private async loadOutbox(): Promise<void> {
    this.outboxItems = await this.outboxStore.list();
    this.outboxCount = this.outboxItems.length;
  }

  private async openOutbox(): Promise<void> {
    await this.loadOutbox();
    this.showOutbox = true;
  }

  private openPasswordSheet(): void {
    this.oldPassword = '';
    this.newPassword = '';
    this.confirmPassword = '';
    this.oldPasswordError = '';
    this.newPasswordError = '';
    this.confirmPasswordError = '';
    this.passwordError = '';
    this.showPasswordSheet = true;
  }

  private openServerSheet(): void {
    this.serverUrl = HttpClient.getInstance().getBaseUrl();
    this.serverUrlError = '';
    this.showServerSheet = true;
  }

  private async saveServerUrl(): Promise<void> {
    const url = this.serverUrl.trim();
    if (url.length === 0) {
      this.serverUrlError = '请输入服务器地址';
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.serverUrlError = '地址需以 http:// 或 https:// 开头';
      return;
    }
    this.savingServerUrl = true;
    try {
      await ServerConfigStore.getInstance().setCustomBaseUrl(getContext(this), url);
      HttpClient.getInstance().setBaseUrl(url);
      this.currentBaseUrl = url;
      this.showServerSheet = false;
      promptAction.showToast({ message: '服务器地址已更新', duration: 2000 });
    } finally {
      this.savingServerUrl = false;
    }
  }

  private async resetServerUrl(): Promise<void> {
    this.savingServerUrl = true;
    try {
      await ServerConfigStore.getInstance().clearCustomBaseUrl(getContext(this));
      HttpClient.getInstance().setBaseUrl(BASE_URL);
      this.currentBaseUrl = BASE_URL;
      this.serverUrl = BASE_URL;
      this.serverUrlError = '';
      promptAction.showToast({ message: '已恢复默认地址', duration: 2000 });
    } finally {
      this.savingServerUrl = false;
    }
  }

  private canManageMembers(): boolean {
    return can(this.user, 'ManageMembers');
  }

  private canApprovePending(): boolean {
    return can(this.user, 'AssignPending');
  }

  private canOpenManage(): boolean {
    return can(this.user, 'ManageDepts') || can(this.user, 'ViewRegisterCode') ||
      can(this.user, 'ChangeRegisterCode') || can(this.user, 'ManageInviteLinks') ||
      can(this.user, 'TransferPresidency');
  }

  private permissionRows(): PermissionDisplay[] {
    const permissions = this.permissions;
    if (permissions === null) return [];
    const rows: PermissionDisplay[] = [];
    rows.push({
      desc: `可见范围 · ${this.scopeLabel(permissions.view_scope)}`,
      ok: permissions.view_scope !== 'none',
      showIcon: false,
    });
    rows.push(this.boolRow('审批与成员处置', permissions.manage_members));
    rows.push(this.boolRow('分配角色', permissions.set_role));
    rows.push(this.boolRow('新建任务', permissions.create_task));
    rows.push(this.boolRow('新建课题', permissions.create_plan));
    rows.push(this.boolRow('修改他人任务', permissions.update_any_task));
    if (permissions.manage_depts !== undefined) {
      rows.push(this.boolRow('部门与组织', permissions.manage_depts));
    }
    if (permissions.view_register_code !== undefined) {
      rows.push(this.boolRow('查看注册口令', permissions.view_register_code));
    }
    if (permissions.change_register_code !== undefined) {
      rows.push(this.boolRow('更换注册口令', permissions.change_register_code));
    }
    if (permissions.manage_invite_links !== undefined) {
      rows.push(this.boolRow('招募链接管理', permissions.manage_invite_links));
    }
    if (permissions.transfer_presidency !== undefined) {
      rows.push(this.boolRow('会长移交', permissions.transfer_presidency));
    }
    return rows;
  }

  private boolRow(desc: string, value: boolean): PermissionDisplay {
    return { desc: desc, ok: value, showIcon: true };
  }

  private scopeLabel(scope: string): string {
    if (scope === 'all') return '全社团';
    if (scope === 'dept') return '本部门';
    if (scope === 'self') return '本人';
    return '无权限';
  }

  private profileInitial(): string {
    const name: string = this.user?.name ?? '';
    if (name.length === 0) {
      return '?';
    }
    return name.substring(0, 1);
  }

  private roleLabel(role: string): string {
    if (role === 'president') return '会长';
    if (role === 'vice_president') return '副会长';
    if (role === 'lead') return '部长';
    if (role === 'vice_lead') return '副部长';
    if (role === 'member') return '成员';
    return '未分配';
  }

  private maskPhone(phone: string): string {
    if (phone.length === 11) return `${phone.substring(0, 3)}****${phone.substring(7)}`;
    return phone.length > 0 ? phone : '未获取';
  }

  private isPasswordValid(value: string): boolean {
    const bytes: number = new util.TextEncoder().encodeInto(value).length;
    if (bytes < 8 || bytes > 32) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 0x21 || code > 0x7E) {
        return false;
      }
    }
    return true;
  }

  private validatePassword(): boolean {
    this.oldPasswordError = '';
    this.newPasswordError = '';
    this.confirmPasswordError = '';
    this.passwordError = '';
    let valid = true;
    if (this.oldPassword.length === 0) {
      this.oldPasswordError = '请输入当前密码';
      valid = false;
    }
    if (!this.isPasswordValid(this.newPassword)) {
      this.newPasswordError = '新密码需为 8–32 字节，且仅含数字、英文或符号';
      valid = false;
    }
    if (this.newPassword !== this.confirmPassword) {
      this.confirmPasswordError = '两次输入的新密码不一致';
      valid = false;
    }
    return valid;
  }

  private async changePassword(): Promise<void> {
    if (!this.validatePassword()) return;
    this.changingPassword = true;
    try {
      const request: ChangePasswordRequest = {
        old_password: this.oldPassword,
        new_password: this.newPassword,
      };
      const response = await this.authApi.changePassword(request);
      if (!response.ok) {
        const fields = response.error?.fields;
        if (fields !== undefined) {
          if (fields['old_password'] !== undefined) this.oldPasswordError = fields['old_password'];
          if (fields['new_password'] !== undefined) this.newPasswordError = fields['new_password'];
        }
        this.passwordError = response.error?.message ?? '修改失败，请重试';
        return;
      }
      this.showPasswordSheet = false;
      promptAction.showToast({ message: '密码修改成功，本机仍保持登录', duration: 2000 });
    } finally {
      this.changingPassword = false;
    }
  }

  private async syncOutbox(): Promise<void> {
    this.syncingOutbox = true;
    const result: OutboxSyncResult = await OutboxSync.syncAll();
    await this.loadOutbox();
    this.syncingOutbox = false;
    if (result.remaining === 0) {
      this.showOutbox = false;
      promptAction.showToast({ message: `已同步 ${result.synced} 条`, duration: 2000 });
    } else {
      promptAction.showToast({ message: result.last_error.length > 0 ? result.last_error : '仍有待同步项', duration: 2000 });
    }
  }

  private async discardOne(id: string): Promise<void> {
    await this.outboxStore.remove(id);
    await this.loadOutbox();
  }

  private async discardAll(): Promise<void> {
    await this.outboxStore.clear();
    await this.loadOutbox();
    this.showOutbox = false;
  }

  private confirmLogout(): void {
    promptAction.showDialog({
      title: '退出登录？',
      message: '本地缓存与待同步的更改会被一起清空。',
      buttons: [
        { text: '取消', color: '#4A5565' },
        { text: '退出', color: '#FB2C36' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.logout();
      }
    });
  }

  private async logout(): Promise<void> {
    await this.authApi.logout();
    await SessionStore.clearAll();
    replaceTo('pages/LoginPage');
  }
}
