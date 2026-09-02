import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      if (deviceInfo.deviceType === '2in1') {
        this.applyDesktopTitleBar(windowStage);
      }
    });
  }

  /**
   * 2in1: hide the system title bar so the page extends into it, leaving the
   * window three buttons overlaid at the top-right; the app draws its own
   * black title row beside them (Index.desktopTitleBar).
   */
  private applyDesktopTitleBar(windowStage: window.WindowStage): void {
    try {
      windowStage.getMainWindowSync().setWindowDecorVisible(false);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to hide window decor. Cause: %{public}s', JSON.stringify(err));
    }
    try {
      // Light three-button glyphs so they stay visible on the black title bar.
      // Note: setWindowContainerColor needs a system permission, the black
      // background comes from the page's own title row instead.
      const buttonStyle: window.DecorButtonStyle = {
        colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      };
      windowStage.getMainWindowSync().setDecorButtonStyle(buttonStyle);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set decor button style. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
