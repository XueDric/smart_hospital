import { AppRouter, RouteName, SessionStore, ThemeManager } from 'common-core';
import { PatientRoot } from 'feature-patient';
import { DoctorRoot } from 'feature-doctor';
import { AdminRoot } from 'feature-admin';

@Entry
@ComponentV2
struct Index {
  @Local route: string = RouteName.LOGIN;
  // AppColor 是静态 getter，不是响应式数据。主题切换后只能靠重建页面树让所有颜色重新取值，
  // 这里用奇偶分支配合 themeTick，保证每次切换都落到另一个分支上。
  @Local themeTick: number = 0;

  aboutToAppear(): void {
    AppRouter.getInstance().setObserver((name: string) => {
      this.route = name;
    });
    ThemeManager.getInstance().setOnChange(() => {
      this.themeTick = this.themeTick + 1;
    });
    // 已登录会话重启后按角色回到对应端首页，避免被统一踢回患者登录页。
    const role: string = SessionStore.getRole();
    if (SessionStore.hasToken() && role === 'doctor') {
      AppRouter.getInstance().replace(RouteName.DOCTOR_QUEUE);
    } else if (SessionStore.hasToken() && role === 'admin') {
      AppRouter.getInstance().replace(RouteName.ADMIN_DASHBOARD);
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

  build() {
    Stack() {
      if (this.themeTick % 2 === 0) {
        Column() {
          this.renderRoot()
        }
        .width('100%')
        .height('100%')
      } else {
        Row() {
          this.renderRoot()
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
