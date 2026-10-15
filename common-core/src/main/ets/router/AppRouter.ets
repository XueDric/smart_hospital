export class RouteName {
  static readonly LOGIN: string = 'login';
  static readonly HOME: string = 'home';
  static readonly TRIAGE: string = 'triage';
  static readonly PREVISIT: string = 'previsit';
  static readonly BOOKING: string = 'booking';
  static readonly APPOINTMENTS: string = 'appointments';
  static readonly RECORDS: string = 'records';
  static readonly RECORD_DETAIL: string = 'record-detail';
  static readonly NOTICE: string = 'notice';
  static readonly PROFILE: string = 'profile';
  // 医生端
  static readonly DOCTOR_LOGIN: string = 'doctor-login';
  static readonly DOCTOR_QUEUE: string = 'doctor-queue';
  static readonly DOCTOR_RECORD: string = 'doctor-record';
  // 管理端
  static readonly ADMIN_LOGIN: string = 'admin-login';
  static readonly ADMIN_DASHBOARD: string = 'admin-dashboard';
  static readonly ADMIN_DEPARTMENTS: string = 'admin-departments';
  static readonly ADMIN_DOCTORS: string = 'admin-doctors';
  static readonly ADMIN_SCHEDULES: string = 'admin-schedules';
  static readonly ADMIN_USERS: string = 'admin-users';
  static readonly ADMIN_AI: string = 'admin-ai';
  static readonly ADMIN_KB: string = 'admin-kb';
}

export class AppRouter {
  private static instance: AppRouter = new AppRouter();
  private currentRoute: string = RouteName.LOGIN;
  private observer?: (route: string) => void;
  private routeGuard?: (route: string) => string;
  private params: Record<string, Object> = {};
  private routeStack: string[] = [];

  static getInstance(): AppRouter {
    return AppRouter.instance;
  }

  setObserver(observer: (route: string) => void): void {
    this.observer = observer;
    observer(this.currentRoute);
  }

  setGuard(guard: (route: string) => string): void {
    this.routeGuard = guard;
  }

  current(): string {
    return this.currentRoute;
  }

  getParams(): Record<string, Object> {
    return this.params;
  }

  getParam(key: string): Object | undefined {
    return this.params[key];
  }

  replace(route: string, params?: Record<string, Object>): void {
    const target = this.routeGuard !== undefined ? this.routeGuard(route) : route;
    this.params = params ?? {};
    this.currentRoute = target;
    if (this.observer) {
      this.observer(target);
    }
  }

  push(route: string, params?: Record<string, Object>): void {
    this.routeStack.push(this.currentRoute);
    this.replace(route, params);
  }

  back(): void {
    const previous = this.routeStack.pop();
    this.replace(previous ?? RouteName.HOME);
  }

  reset(route: string): void {
    this.routeStack = [];
    this.replace(route);
  }
}
