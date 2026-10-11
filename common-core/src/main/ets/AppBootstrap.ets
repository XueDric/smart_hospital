import { common } from '@kit.AbilityKit';
import { ApiConfig } from './config/ApiConfig';
import { SessionStore } from './storage/SessionStore';

export class AppBootstrap {
  private static context: common.UIAbilityContext | undefined = undefined;

  static initialize(context: common.UIAbilityContext): void {
    AppBootstrap.context = context;
    SessionStore.initialize(context);
    ApiConfig.restore(SessionStore.getApiMode(), SessionStore.getBaseUrl());
  }

  static getContext(): common.UIAbilityContext | undefined {
    return AppBootstrap.context;
  }
}
