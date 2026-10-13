import { AppColor, AppRouter, RouteName, SessionStore } from 'common-core';
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

  aboutToAppear(): void {
    if (this.route !== RouteName.ADMIN_LOGIN && !SessionStore.hasToken()) {
      AppRouter.getInstance().reset(RouteName.ADMIN_LOGIN);
    }
  }

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
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.SURFACE)
            Text('管理端')
              .fontSize(12)
              .fontColor(AppColor.PRIMARY_SOFT)
              .margin({ top: 4 })

            Column() {
              ForEach(this.items, (item: AdminNavItem) => {
                Button(item.label)
                  .width('100%')
                  .height(44)
                  .fontSize(15)
                  .fontColor(this.route === item.route ? AppColor.PRIMARY_DARK : AppColor.TEXT)
                  .backgroundColor(this.route === item.route ? AppColor.PRIMARY_SOFT : Color.Transparent)
                  .borderRadius(8)
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
            .margin({ top: 24 })

            Button('退出登录')
              .width('100%')
              .height(40)
              .fontSize(14)
              .fontColor(AppColor.PRIMARY_SOFT)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: AppColor.PRIMARY_DARK })
              .borderRadius(8)
              .onClick(() => this.logout())
          }
          .width(150)
          .height('100%')
          .padding({ left: 12, right: 12, top: 24, bottom: 16 })
          .backgroundColor(AppColor.TEXT)

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
        .fontSize(18)
        .fontColor(AppColor.TEXT_SECONDARY)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
