import { common } from '@kit.AbilityKit';
import { ApiConfig } from './config/ApiConfig';
import { AppRouter } from './router/AppRouter';
import { AuthGuard } from './router/AuthGuard';
import { FileStore } from './storage/FileStore';
import { KeyValueStore } from './storage/KeyValueStore';
import { SessionStore } from './storage/SessionStore';
import { ThemeManager } from './ui/ThemeManager';

export class AppBootstrap {
  private static context: common.UIAbilityContext | undefined = undefined;

  static initialize(context: common.UIAbilityContext): void {
    AppBootstrap.context = context;
    SessionStore.initialize(context);
    KeyValueStore.initialize(context);
    FileStore.initialize(context);
    ApiConfig.restore(SessionStore.getApiMode(), SessionStore.getBaseUrl());
    ThemeManager.getInstance().initialize();
    AppRouter.getInstance().setGuard(AuthGuard.reroute);
  }

  static getContext(): common.UIAbilityContext | undefined {
    return AppBootstrap.context;
  }
}
