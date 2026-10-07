// 负责人：彭翌菲
// 负责应用生命周期初始化、基础地址和本地状态加载，
// 接收邀请深链并在恢复前台时触发离线队列同步。

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { TokenStore } from '../store/TokenStore';
import { OutboxStore } from '../store/OutboxStore';
import { OutboxSync } from '../store/OutboxSync';
import { HttpClient } from '../api/HttpClient';
import { extractInviteToken, openInviteRegistration, rememberInviteTokenFromUri } from '../utils/InviteDeepLink';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    rememberInviteTokenFromUri(want.uri);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    HttpClient.getInstance().clearBaseUrl();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const tokenStore = TokenStore.getInstance();
    const outboxStore = OutboxStore.getInstance();
    Promise.all([tokenStore.init(this.context), outboxStore.init(this.context)]).then(() => {
      windowStage.loadContent('pages/ServerConfigPage', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load ServerConfigPage. Cause: %{public}s', JSON.stringify(err));
        }
      });
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Store init failed. Cause: %{public}s', JSON.stringify(err));
      windowStage.loadContent('pages/ServerConfigPage', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load ServerConfigPage. Cause: %{public}s', JSON.stringify(err));
        }
      });
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const inviteToken: string = rememberInviteTokenFromUri(want.uri);
    if (inviteToken.length > 0 && HttpClient.getInstance().hasBaseUrl()) {
      openInviteRegistration(inviteToken);
    }
  }

  onForeground(): void {
    if (!HttpClient.getInstance().hasBaseUrl()) {
      return;
    }
    OutboxSync.syncAll().then(() => {
      hilog.info(DOMAIN, 'testTag', 'Outbox sync completed');
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, 'testTag', 'Outbox sync skipped. Cause: %{public}s', JSON.stringify(err));
    });
  }
}
