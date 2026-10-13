import { AppRouter, RouteName } from 'common-core';
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
    this.route = AppRouter.getInstance().current();
  }

  build() {
    Stack() {
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
      .width('100%')
      .height('100%')
  }
}
