/**
 * 路由工具函数
 * 统一处理 router 调用，避免 ArkTS 严格模式下的对象字面量类型问题
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'RouterUtils';

export function replaceTo(url: string, params?: Object): void {
  try {
    const opt: router.RouterOptions = { url: url };
    if (params !== undefined) {
      opt.params = params;
    }
    router.replaceUrl(opt);
  } catch (err) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceTo failed: %{public}s', JSON.stringify(err));
  }
}

export function pushTo(url: string, params?: Object): void {
  try {
    const opt: router.RouterOptions = { url: url };
    if (params !== undefined) {
      opt.params = params;
    }
    router.pushUrl(opt);
  } catch (err) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'pushTo failed: %{public}s', JSON.stringify(err));
  }
}

export function backPage(): void {
  try {
    router.back();
  } catch (err) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'backPage failed: %{public}s', JSON.stringify(err));
  }
}
