import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppBootstrap } from 'common-core';
import { registerPatientFeature } from 'feature-patient';
import { registerDoctorFeature } from 'feature-doctor';
import { registerAdminFeature } from 'feature-admin';

const DOMAIN = 0x0000;

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
     * ★ 2026-10-17（评审 P2-14）：先等令牌从**安全存储**读出来再加载首屏。
     *
     * `onWindowStageCreate` 的签名是 `void`（不能改成 async，否则与基类不兼容），
     * 所以用 `.then` 串起来。`whenReady()` 内部已把异常吞掉并按"未登录"处理，
     * 因此这里不需要再写失败分支 —— **任何情况下都会 loadContent**，
     * 不能因为一次存储异常让用户看到白屏。
     */
    AppBootstrap.whenReady().then(() => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'SmartHospital', 'Failed to load Index: %{public}s', JSON.stringify(err));
        }
      });
    });
  }
}
