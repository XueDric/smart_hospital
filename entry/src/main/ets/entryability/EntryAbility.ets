import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppBootstrap } from 'common-core';
import { registerPatientFeature } from 'feature-patient';
import { registerDoctorFeature } from 'feature-doctor';
import { registerAdminFeature } from 'feature-admin';

const DOMAIN = 0x0000;
/** 会话闸门的硬期限：安全存储挂起时不能把用户卡在白屏上。 */
const SESSION_GATE_TIMEOUT_MS: number = 1200;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppBootstrap.initialize(this.context);
    // 三个端统一注册：首装时本地还没有 role，若只按 role 注册会让医生端、管理端入口永远不可达（F04）。
    registerPatientFeature();
    registerDoctorFeature();
    registerAdminFeature();
    hilog.info(DOMAIN, 'SmartHospital', 'EntryAbility created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    /*
     * ★ 2026-10-17（评审 P2-14 + 复查）：先等令牌从**安全存储**读出来再加载首屏。
     *
     * `onWindowStageCreate` 的签名是 `void`（改成 async 与基类不兼容），
     * 所以用 Promise 串起来。`whenReady()` 内部已把异常吞掉、按"未登录"处理，
     * 因此这里不需要失败分支 —— **任何情况下都会 loadContent**。
     *
     * 为什么还要 `Promise.race` 一条硬期限：`whenReady()` 只 `await` 存储读取，
     * 一旦系统安全存储挂起（模拟器上偶发），它就永远不返回，用户看到的是**永久白屏**。
     * 到点按"未登录"启动 —— 宁可多一次登录，也不能白屏。
     */
    const gate: Promise<void> = AppBootstrap.whenReady();
    const timeout: Promise<void> = new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, SESSION_GATE_TIMEOUT_MS);
    });
    Promise.race([gate, timeout]).then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'SmartHospital', 'Failed to load Index: %{public}s', JSON.stringify(err));
        }
      });
    });
  }
}
