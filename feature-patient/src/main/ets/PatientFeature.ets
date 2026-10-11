import { AppRouter, RouteName } from 'common-core';

export function registerPatientFeature(): void {
  AppRouter.getInstance().replace(RouteName.LOGIN);
}
