import { AppColor, AppText, RouteName } from 'common-core';
import { DoctorLoginPage } from './pages/DoctorLoginPage';
import { EmrEditPage } from './pages/EmrEditPage';
import { RecordHistoryPage } from './pages/RecordHistoryPage';
import { VisitQueuePage } from './pages/VisitQueuePage';

@ComponentV2
export struct DoctorRoot {
  @Param route: string = RouteName.DOCTOR_LOGIN;

  build() {
    Stack() {
      if (this.route === RouteName.DOCTOR_LOGIN) {
        DoctorLoginPage()
          .width('100%')
          .height('100%')
      } else if (this.route === RouteName.DOCTOR_QUEUE) {
        VisitQueuePage()
          .width('100%')
          .height('100%')
      } else if (this.route === RouteName.DOCTOR_RECORD) {
        EmrEditPage()
          .width('100%')
          .height('100%')
      } else if (this.route === RouteName.DOCTOR_RECORD_HISTORY) {
        RecordHistoryPage()
          .width('100%')
          .height('100%')
      } else {
        this.placeholder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
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
