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

  /*
   * ★ 2026-10-17（评审 P2-14）：等**安全存储里的令牌**读完。
   *
   * 为什么需要这个闸门：令牌改存 Asset Store Kit（系统安全存储）后只有 Promise API，
   * 而 `Index.aboutToAppear` 判断"是否已登录"是同步的（`SessionStore.hasToken()`）。
   * 入口若在令牌读完之前就 `loadContent`，已登录用户会先闪一下登录页，
   * 更糟时会被 `AuthGuard` 直接踢回登录。
   * ⇒ 入口在 `loadContent` 前 `await AppBootstrap.whenReady()`。
   *
   * ⚠ 读失败**不阻塞启动**：安全存储不可用时按"未登录"处理（重登一次即可），
   *   不能让一个存储异常把应用卡在白屏。
   */
  static async whenReady(): Promise<void> {
    try {
      await SessionStore.ready();
    } catch (error) {
      console.error(`[AppBootstrap] 会话令牌读取失败，按未登录启动：${(error as Error).message}`);
    }
  }
}
