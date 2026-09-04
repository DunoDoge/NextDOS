import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';

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
      } else {
        this.applyImmersiveMode(windowStage);
      }
      this.applyNarrowScreenOrientation(windowStage);
    });
  }

  /**
   * Phone and tablet run edge-to-edge: the window extends behind the system
   * bars and the bars are hidden entirely, so no white status/navigation
   * strip is left. The system reveals the bars temporarily on an edge swipe
   * and auto-hides them again. 2in1 keeps its windowed desktop layout.
   */
  private applyImmersiveMode(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to extend behind system bars. Cause: %{public}s', JSON.stringify(err));
      });
      win.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to hide system bars. Cause: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to apply immersive mode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Narrow screens (a phone held in portrait) run the emulator forced to
   * landscape: the DOS view is barely usable in portrait, and the centered
   * settings sheet only renders centered above 600vp of window width. Wide
   * windows keep whatever orientation they already have.
   */
  private applyNarrowScreenOrientation(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      const rect = win.getWindowProperties().windowRect;
      const density = display.getDefaultDisplaySync().densityPixels;
      if (rect.width / density < 600) {
        win.setPreferredOrientation(window.Orientation.LANDSCAPE)
          .catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'testTag', 'Failed to force landscape. Cause: %{public}s', JSON.stringify(err));
          });
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read window for orientation. Cause: %{public}s', JSON.stringify(err));
    }
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
