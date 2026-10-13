import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppBootstrap, SessionStore } from 'common-core';
import { registerPatientFeature } from 'feature-patient';
import { registerDoctorFeature } from 'feature-doctor';
import { registerAdminFeature } from 'feature-admin';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppBootstrap.initialize(this.context);
    const role = SessionStore.getRole();
    if (role === 'doctor') {
      registerDoctorFeature();
    } else if (role === 'admin') {
      registerAdminFeature();
    } else {
      registerPatientFeature();
    }
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
