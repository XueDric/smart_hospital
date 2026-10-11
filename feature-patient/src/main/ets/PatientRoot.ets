import { AppRouter, RouteName, SessionStore } from 'common-core';
import { BottomNav } from './ui/CommonComponents';
import { AppointmentsPage } from './pages/AppointmentsPage';
import { BookingPage } from './pages/BookingPage';
import { HomePage } from './pages/HomePage';
import { LoginPage } from './pages/LoginPage';
import { NoticePage } from './pages/NoticePage';
import { PrevisitPage } from './pages/PrevisitPage';
import { ProfilePage } from './pages/ProfilePage';
import { RecordDetailPage } from './pages/RecordDetailPage';
import { RecordsPage } from './pages/RecordsPage';
import { TriagePage } from './pages/TriagePage';
import { AppColor } from './ui/Theme';

@ComponentV2
export struct PatientRoot {
  @Param route: string = RouteName.LOGIN;

  aboutToAppear(): void {
    if (this.route !== RouteName.LOGIN && !SessionStore.hasToken()) {
      AppRouter.getInstance().reset(RouteName.LOGIN);
    }
  }

  private isTabRoute(route: string): boolean {
    return route === RouteName.HOME || route === RouteName.TRIAGE ||
      route === RouteName.BOOKING || route === RouteName.APPOINTMENTS ||
      route === RouteName.PROFILE;
  }

  build() {
    Stack() {
      if (this.route === RouteName.LOGIN) {
        LoginPage()
          .width('100%')
          .height('100%')
      } else {
        Column() {
          Column() {
            this.page()
          }
          .layoutWeight(1)
          .width('100%')

          if (this.isTabRoute(this.route)) {
            BottomNav({ currentRoute: this.route })
          }
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  page() {
    if (this.route === RouteName.HOME) {
      HomePage()
    } else if (this.route === RouteName.TRIAGE) {
      TriagePage()
    } else if (this.route === RouteName.PREVISIT) {
      PrevisitPage()
    } else if (this.route === RouteName.BOOKING) {
      BookingPage()
    } else if (this.route === RouteName.APPOINTMENTS) {
      AppointmentsPage()
    } else if (this.route === RouteName.RECORDS) {
      RecordsPage()
    } else if (this.route === RouteName.RECORD_DETAIL) {
      RecordDetailPage()
    } else if (this.route === RouteName.NOTICE) {
      NoticePage()
    } else if (this.route === RouteName.PROFILE) {
      ProfilePage()
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
