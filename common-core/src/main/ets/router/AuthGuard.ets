import { RouteName } from './AppRouter';
import { SessionStore } from '../storage/SessionStore';

export class AuthGuard {
  static reroute(route: string): string {
    if (AuthGuard.isLoginRoute(route)) {
      return route;
    }
    if (route.startsWith('doctor-')) {
      return AuthGuard.hasRole('doctor') ? route : RouteName.DOCTOR_LOGIN;
    }
    if (route.startsWith('admin-')) {
      return AuthGuard.hasRole('admin') ? route : RouteName.ADMIN_LOGIN;
    }
    return AuthGuard.hasRole('patient') ? route : RouteName.LOGIN;
  }

  private static isLoginRoute(route: string): boolean {
    return route === RouteName.LOGIN || route === RouteName.DOCTOR_LOGIN ||
      route === RouteName.ADMIN_LOGIN;
  }

  private static hasRole(role: string): boolean {
    if (!SessionStore.hasToken()) {
      return false;
    }
    return SessionStore.getRole() === role;
  }
}
