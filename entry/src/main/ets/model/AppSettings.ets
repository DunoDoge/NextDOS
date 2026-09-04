import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'nextdos_settings';
const KEY_KEYBOARD_VISIBLE: string = 'keyboardVisible';
const KEY_KEYBOARD_OPACITY: string = 'keyboardOpacity';
const DEFAULT_OPACITY: number = 0.8;

/**
 * Persistence for the settings sheet. AppStorage carries the live values
 * between Index and SettingsSheet; this store keeps them across process
 * restarts. Load once in Index.aboutToAppear and save on every change.
 */
export class AppSettings {
  static loadKeyboardVisible(context: common.UIAbilityContext): boolean {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: STORE_NAME });
      return prefs.getSync(KEY_KEYBOARD_VISIBLE, false) as boolean;
    } catch {
      return false;
    }
  }

  static loadKeyboardOpacity(context: common.UIAbilityContext): number {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: STORE_NAME });
      return prefs.getSync(KEY_KEYBOARD_OPACITY, DEFAULT_OPACITY) as number;
    } catch {
      return DEFAULT_OPACITY;
    }
  }

  static save(context: common.UIAbilityContext, keyboardVisible: boolean, keyboardOpacity: number): void {
    try {
      const prefs: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: STORE_NAME });
      prefs.putSync(KEY_KEYBOARD_VISIBLE, keyboardVisible);
      prefs.putSync(KEY_KEYBOARD_OPACITY, keyboardOpacity);
      prefs.flush().catch(() => {
      });
    } catch {
      // Store unavailable this frame: settings stay in-memory until next save.
    }
  }
}
