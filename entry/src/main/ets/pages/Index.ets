import { AppRouter, RouteName } from 'common-core';
import { PatientRoot } from 'feature-patient';

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
      PatientRoot({ route: this.route })
        .width('100%')
        .height('100%')
    }
      .width('100%')
      .height('100%')
  }
}
