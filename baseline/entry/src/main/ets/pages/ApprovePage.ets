// 负责人：杨睿（前端组长）
// 权限门卫页（审批入口）—— 校验 AssignPending 权限（会长 / 副会长），无权限自动跳回首页
import PendingApprovalPage from './PendingApprovalPage';
import { can, PermissionStore } from '../store/PermissionStore';
import { replaceTo } from '../utils/RouterUtils';

@Entry
@Component
struct ApprovePage {
  aboutToAppear(): void {
    if (!can(PermissionStore.getInstance().userInfo, 'AssignPending')) {
      replaceTo('pages/Index');
    }
  }

  build() {
    Column() {
      PendingApprovalPage()
    }
    .width('100%')
    .height('100%')
  }
}
