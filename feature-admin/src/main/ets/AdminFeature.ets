import { AppRouter, RouteName } from 'common-core';

export function registerAdminFeature(): void {
  AppRouter.getInstance().replace(RouteName.ADMIN_LOGIN);
}
