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
}

export class AppRouter {
  private static instance: AppRouter = new AppRouter();
  private currentRoute: string = RouteName.LOGIN;
  private observer?: (route: string) => void;
  private params: Record<string, Object> = {};
  private routeStack: string[] = [];

  static getInstance(): AppRouter {
    return AppRouter.instance;
  }

  setObserver(observer: (route: string) => void): void {
    this.observer = observer;
    observer(this.currentRoute);
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
    this.params = params ?? {};
    this.currentRoute = route;
    if (this.observer) {
      this.observer(route);
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
