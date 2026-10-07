// 负责人：彭翌菲
// 作为待分配账号的落地页，展示审核状态和操作说明，
// 支持刷新分配状态并退出登录。

import { promptAction } from '@kit.ArkUI';
import { AuthApi } from '../api/AuthApi';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { SessionStore } from '../store/SessionStore';
import { replaceTo } from '../utils/RouterUtils';

const PENDING_PRIMARY: string = '#155DFC';
const PENDING_ICON_BG: string = '#F5F3FF';
const PENDING_TITLE: string = '#101828';
const PENDING_DESCRIPTION: string = '#6A7282';
const PENDING_CARD_BORDER: string = '#F3F4F6';
const PENDING_STATUS_DIVIDER: string = '#F9FAFB';
const PENDING_CARD_HEADING: string = '#1E2939';
const PENDING_STEP_TEXT: string = '#4A5565';
const PENDING_MUTED: string = '#99A1AF';
const PENDING_PHONE: string = '#364153';
const PENDING_STATUS: string = '#A855F7';
const PENDING_BLUE_BULLET: string = '#2B7FFF';
const PENDING_GREEN_BULLET: string = '#00C950';
const PENDING_BLUE_SHADOW: string = '#BEDBFF';
const PENDING_ERROR: string = '#FB2C36';

@Entry
@Component
struct PendingPage {
  @State phone: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';

  private authApi: AuthApi = new AuthApi();
  private permissionStore: PermissionStore = PermissionStore.getInstance();

  aboutToAppear(): void {
    this.phone = this.permissionStore.userInfo?.phone ?? '';
    this.refreshStatus(false);
  }

  build() {
    Column() {
      Column() {
        Stack() {
          Circle()
            .width(96)
            .height(96)
            .fill(PENDING_ICON_BG)

          Image($r('app.media.icon_clock_purple_figma'))
            .width(44)
            .height(44)
        }
        .width(96)
        .height(96)
        .margin({ bottom: 32 })

        Text('等待管理员分配')
          .fontSize(24)
          .fontWeight(700)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(PENDING_TITLE)
          .lineHeight(32)
          .margin({ bottom: 12 })

        Text('账号已注册成功，但还没有被分配部门与角色，无法进入主空间。')
          .fontSize(14)
          .fontWeight(400)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(PENDING_DESCRIPTION)
          .lineHeight(22.75)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: 280 })

        Column({ space: 12 }) {
          Text('接下来会发生什么')
            .width('100%')
            .fontSize(14)
            .fontWeight(600)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(PENDING_CARD_HEADING)
            .lineHeight(20)

          this.stepRow(PENDING_BLUE_BULLET, '把姓名告诉会长或副会长。')
          this.stepRow(PENDING_BLUE_BULLET, '他们在「管理 · 待分配审批」里为你分配部门与角色。')
          this.stepRow(PENDING_GREEN_BULLET, '分配生效后重新登录，首页「我的任务」就会出现在你面前。')
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 16 })
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: PENDING_CARD_BORDER })
        .borderRadius(16)
        .shadow({
          radius: 2,
          color: '#0D000000',
          offsetX: 0,
          offsetY: 1
        })
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Row() {
          Text('注册手机号')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(PENDING_MUTED)
            .lineHeight(20)
          Blank()
          Text(this.maskPhone(this.phone))
            .fontSize(14)
            .fontWeight(500)
            .fontFamily('Inter')
            .fontFeature('"tnum" 1')
            .fontColor(PENDING_PHONE)
            .lineHeight(20)
        }
        .width('100%')

        Row() {
          Text('账号状态')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(PENDING_MUTED)
            .lineHeight(20)
          Blank()
          Text('待分配')
            .fontSize(14)
            .fontWeight(500)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(PENDING_STATUS)
            .lineHeight(20)
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ top: 8 })
        .border({ width: { top: 1 }, color: PENDING_STATUS_DIVIDER })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: PENDING_CARD_BORDER })
      .borderRadius(16)
      .margin({ bottom: 16 })

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .width('100%')
          .fontSize(12)
          .fontWeight(400)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(PENDING_ERROR)
          .lineHeight(20)
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })
      }

      Button(this.loading ? '刷新中…' : '刷新状态')
        .width('100%')
        .height(56)
        .fontSize(16)
        .fontWeight(600)
        .fontFamily('Noto Sans CJK SC')
        .fontColor('#FFFFFF')
        .backgroundColor(PENDING_PRIMARY)
        .borderRadius(12)
        .shadow({
          radius: 15,
          color: PENDING_BLUE_SHADOW,
          offsetX: 0,
          offsetY: 10
        })
        .enabled(!this.loading)
        .onClick(() => this.refreshStatus(true))
        .margin({ bottom: 12 })

      Text('退出登录')
        .width('100%')
        .fontSize(14)
        .fontWeight(400)
        .fontFamily('Noto Sans CJK SC')
        .fontColor(PENDING_MUTED)
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 4 })
        .onClick(() => this.handleLogout())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, bottom: 32 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  stepRow(color: string, text: string) {
    Row({ space: 12 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(color)
        .margin({ top: 6 })
      Text(text)
        .layoutWeight(1)
        .fontSize(14)
        .fontWeight(400)
        .fontFamily('Noto Sans CJK SC')
        .fontColor(PENDING_STEP_TEXT)
        .lineHeight(22.75)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  private maskPhone(phone: string): string {
    if (phone.length === 11) {
      return `${phone.substring(0, 3)}****${phone.substring(7)}`;
    }
    return phone.length > 0 ? phone : '未获取';
  }

  async refreshStatus(showResult: boolean): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    const response = await this.authApi.me();
    if (response.ok && response.data !== undefined) {
      const update: UpdateData = {
        user: response.data.member,
        permissions: response.data.permissions,
      };
      this.permissionStore.update(update);
      this.phone = response.data.member.phone;
      if (response.data.member.status === 'active' && response.data.permissions.view_scope !== 'none') {
        if (showResult) {
          promptAction.showToast({ message: '已分配，正在进入…', duration: 2000 });
        }
        replaceTo('pages/Index');
      } else if (showResult) {
        promptAction.showToast({ message: '还没有被分配，请稍后再试', duration: 2000 });
      }
    } else {
      this.errorMsg = response.error?.message ?? '刷新失败，请稍后再试';
    }
    this.loading = false;
  }

  async handleLogout(): Promise<void> {
    await this.authApi.logout();
    await SessionStore.clearAll();
    replaceTo('pages/LoginPage');
  }
}
