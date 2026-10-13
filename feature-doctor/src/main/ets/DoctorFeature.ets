import { AppRouter, RouteName } from 'common-core';

export function registerDoctorFeature(): void {
  AppRouter.getInstance().replace(RouteName.DOCTOR_LOGIN);
}
