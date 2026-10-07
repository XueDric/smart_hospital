// 负责人：杨睿（前端组长）
// 权限门卫页（管理入口）—— 校验 5 个管理权限位（ManageDepts / ViewRegisterCode / ChangeRegisterCode / ManageInviteLinks / TransferPresidency），无权限自动跳回首页
import ManagePage from './ManagePage';
import { can, PermissionStore } from '../store/PermissionStore';
import { Color, FontSize, Space } from '../core/Theme';
import { backPage, replaceTo } from '../utils/RouterUtils';

@Entry
@Component
struct AdminPage {
  aboutToAppear(): void {
    const current = PermissionStore.getInstance().userInfo;
    const allowed = can(current, 'ManageDepts') || can(current, 'ViewRegisterCode') ||
      can(current, 'ChangeRegisterCode') || can(current, 'ManageInviteLinks') ||
      can(current, 'TransferPresidency');
    if (!allowed) {
      replaceTo('pages/Index');
    }
  }

  build() {
    Column() {
      Row() {
        Row({ space: 4 }) {
          Image($r('app.media.icon_chevron_left_primary'))
            .width(18)
            .height(18)

          Text('管理')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor('#155DFC')
        }
        .height('100%')
        .onClick(() => backPage())

        Blank()

        Image($r('app.media.icon_more'))
          .width(20)
          .height(20)
      }
      .width('100%')
      .height(52)
      .padding({ left: Space.page, right: Space.page })
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#FFFFFF')

      Divider()
        .strokeWidth(1)
        .color('#F3F4F6')

      Column() {
        ManagePage()
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F9FAFB')
  }
}