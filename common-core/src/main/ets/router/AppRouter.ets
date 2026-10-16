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
  // 病历版本历史（改进 3，只读：列表 → 详情 → 逐段对比）。
  static readonly DOCTOR_RECORD_HISTORY: string = 'doctor-record-history';
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

/*
 * 路由栈里的一项：**路由名连参数一起存**。
 * 只存路由名的话，`back()` 回到上一页时上一页拿到的是空参数 —— 而"详情页返回列表页"
 * 这类常见场景里列表页本来就不需要参数，所以这个坑平时看不出来；可一旦上一页本身是
 * 靠参数驱动的（病历页靠 appointmentId 重新拉数据），返回就变成白屏/空数据。
 */
class RouteEntry {
  route: string = '';
  params: Record<string, Object> = {};

  constructor(route: string, params: Record<string, Object>) {
    this.route = route;
    this.params = params;
  }
}

export class AppRouter {
  private static instance: AppRouter = new AppRouter();
  private currentRoute: string = RouteName.LOGIN;
  private observer?: (route: string) => void;
  private routeGuard?: (route: string) => string;
  private params: Record<string, Object> = {};
  private routeStack: RouteEntry[] = [];

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
    // 连同当前参数入栈，back() 才能把上一页恢复成"离开时的样子"。
    this.routeStack.push(new RouteEntry(this.currentRoute, this.params));
    this.replace(route, params);
  }

  back(): void {
    const previous = this.routeStack.pop();
    if (previous === undefined) {
      // 空栈（首次进入或 reset 之后）没有"上一页"可回，保持原有兜底：回首页。
      this.replace(RouteName.HOME);
      return;
    }
    this.replace(previous.route, previous.params);
  }

  reset(route: string): void {
    this.routeStack = [];
    this.replace(route);
  }
}
