import { AppRouter, RouteName, SessionStore } from 'common-core';
import { PatientRoot } from 'feature-patient';
import { DoctorRoot } from 'feature-doctor';
import { AdminRoot } from 'feature-admin';

@Entry
@ComponentV2
struct Index {
  @Local route: string = RouteName.LOGIN;

  aboutToAppear(): void {
    AppRouter.getInstance().setObserver((name: string) => {
      this.route = name;
    });
    /*
     * 已登录会话重启后按角色回到对应端首页，避免被统一踢回患者登录页。
     *
     * ★ 2026-10-17 复查：原来缺「患者已登录」分支，患者冷启动必然先渲染一帧登录页，
     *   再由 `LoginPage.aboutToAppear` 二次跳到首页（闪一下 + 多一次路由）。
     *   另外判据要统一到 `hasValidToken()`：过期令牌不该被当成已登录。
     */
    const role: string = SessionStore.getRole();
    if (SessionStore.hasValidToken() && role === 'doctor') {
      AppRouter.getInstance().replace(RouteName.DOCTOR_QUEUE);
    } else if (SessionStore.hasValidToken() && role === 'admin') {
      AppRouter.getInstance().replace(RouteName.ADMIN_DASHBOARD);
    } else if (SessionStore.hasValidToken() && role === 'patient') {
      AppRouter.getInstance().replace(RouteName.HOME);
    } else {
      this.route = AppRouter.getInstance().current();
    }
  }

  @Builder
  renderRoot(): void {
    if (this.route.startsWith('doctor-')) {
      DoctorRoot({ route: this.route })
        .width('100%')
        .height('100%')
    } else if (this.route.startsWith('admin-')) {
      AdminRoot({ route: this.route })
        .width('100%')
        .height('100%')
    } else {
      PatientRoot({ route: this.route })
        .width('100%')
        .height('100%')
    }
  }

  /*
   * ★ 2026-10-17（评审 P2-11）：这里原来是靠 `themeTick % 2` 在两个分支
   * （`Column` / `Row`）之间来回切，**借"重建整棵页面树"逼所有颜色重新取值**。
   * 那等于每切一次主题就重启一次界面：滚动位置、输入框内容、在途请求的回调
   * 全部丢失，还会闪一下。
   *
   * 现在由 `ThemeManager`（`@ObservedV2` + `@Trace paletteVersion`）负责通知，
   * `AppColor.*` 在 build 里一读就自动建立依赖，**只有颜色属性被重新求值**，
   * 页面树与状态原地保留。所以这里不需要任何主题相关代码。
   */
  build() {
    Stack() {
      this.renderRoot()
    }
    .width('100%')
    .height('100%')
  }
}
