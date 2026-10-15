import { AppColor, AppRouter, AppSize, AppText, RouteName, SessionStore } from 'common-core';
import { AdminLoginPage } from './pages/AdminLoginPage';
import { AiCenterPage } from './pages/AiCenterPage';
import { DashboardPage } from './pages/DashboardPage';
import { DepartmentsPage } from './pages/DepartmentsPage';
import { DoctorsPage } from './pages/DoctorsPage';
import { KnowledgeBasePage } from './pages/KnowledgeBasePage';
import { SchedulesPage } from './pages/SchedulesPage';
import { UsersPage } from './pages/UsersPage';

class AdminNavItem {
  route: string = '';
  label: string = '';

  constructor(route: string, label: string) {
    this.route = route;
    this.label = label;
  }
}

@ComponentV2
export struct AdminRoot {
  @Param route: string = RouteName.ADMIN_LOGIN;

  private readonly items: AdminNavItem[] = [
    new AdminNavItem(RouteName.ADMIN_DASHBOARD, '运营看板'),
    new AdminNavItem(RouteName.ADMIN_DEPARTMENTS, '科室管理'),
    new AdminNavItem(RouteName.ADMIN_DOCTORS, '医生管理'),
    new AdminNavItem(RouteName.ADMIN_SCHEDULES, '排班号源'),
    new AdminNavItem(RouteName.ADMIN_USERS, '账号管理'),
    new AdminNavItem(RouteName.ADMIN_AI, 'AI 能力中心'),
    new AdminNavItem(RouteName.ADMIN_KB, '知识库')
  ];

  private isLogin(): boolean {
    return this.route === RouteName.ADMIN_LOGIN;
  }

  private logout(): void {
    SessionStore.clearLogin();
    AppRouter.getInstance().reset(RouteName.ADMIN_LOGIN);
  }

  build() {
    Stack() {
      if (this.isLogin()) {
        AdminLoginPage()
          .width('100%')
          .height('100%')
      } else {
        Row() {
          Column() {
            Text('智慧医院')
              .fontSize(AppText.HEADING)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.NAV_TEXT)
            Text('管理端')
              .fontSize(AppText.MICRO)
              .fontColor(AppColor.PRIMARY_SOFT)
              .margin({ top: 4 })

            Column() {
              ForEach(this.items, (item: AdminNavItem) => {
                Button(item.label)
                  .width('100%')
                  .height(AppSize.CONTROL_HEIGHT)
                  .fontSize(AppText.BODY)
                  .fontColor(this.route === item.route ? AppColor.PRIMARY_DARK : AppColor.NAV_TEXT)
                  .backgroundColor(this.route === item.route ? AppColor.PRIMARY_SOFT : Color.Transparent)
                  .borderRadius(AppSize.CONTROL_RADIUS)
                  .margin({ bottom: 4 })
                  .onClick(() => {
                    if (this.route !== item.route) {
                      AppRouter.getInstance().replace(item.route);
                    }
                  })
              }, (item: AdminNavItem) => item.route)
            }
            .width('100%')
            .layoutWeight(1)
            .margin({ top: AppSize.SECTION_GAP })

            Button('退出登录')
              .width('100%')
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.PRIMARY_SOFT)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: AppColor.PRIMARY_DARK })
              .borderRadius(AppSize.CONTROL_RADIUS)
              .onClick(() => this.logout())
          }
          .width(150)
          .height('100%')
          .padding({ left: 12, right: 12, top: 24, bottom: 16 })
          .backgroundColor(AppColor.NAV_BACKGROUND)

          Column() {
            this.content()
          }
          .layoutWeight(1)
          .height('100%')
          .backgroundColor(AppColor.BACKGROUND)
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  content() {
    if (this.route === RouteName.ADMIN_DASHBOARD) {
      DashboardPage()
    } else if (this.route === RouteName.ADMIN_DEPARTMENTS) {
      DepartmentsPage()
    } else if (this.route === RouteName.ADMIN_DOCTORS) {
      DoctorsPage()
    } else if (this.route === RouteName.ADMIN_SCHEDULES) {
      SchedulesPage()
    } else if (this.route === RouteName.ADMIN_USERS) {
      UsersPage()
    } else if (this.route === RouteName.ADMIN_AI) {
      AiCenterPage()
    } else if (this.route === RouteName.ADMIN_KB) {
      KnowledgeBasePage()
    } else {
      this.placeholder()
    }
  }

  @Builder
  placeholder() {
    Column() {
      Text('页面建设中')
        .fontSize(AppText.HEADING)
        .fontColor(AppColor.TEXT_SECONDARY)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
