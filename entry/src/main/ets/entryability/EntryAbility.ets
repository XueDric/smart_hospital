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
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'SmartHospital', 'Failed to load Index: %{public}s', JSON.stringify(err));
      }
    });
  }
}
