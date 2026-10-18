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

  /*
   * ★ 2026-10-17 复查：原来只看"有没有令牌"，不看"过期没"。
   * 服务端会滑动续期，本地这份是快照 —— 过期快照会让用户先闪一下受保护页，
   * 再被第一个 401 踢回来。判据统一用 `hasValidToken()`。
   */
  private static hasRole(role: string): boolean {
    if (!SessionStore.hasValidToken()) {
      return false;
    }
    return SessionStore.getRole() === role;
  }
}
