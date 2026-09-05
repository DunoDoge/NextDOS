import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'NextDOS';
const STORE_NAME: string = 'nextdos_settings';

/** One selectable CPU speed preset of the settings sheet. */
export class CpuCycleOption {
  value: string = 'max';
  label: string = '';
  hint: string = '';

  constructor(value: string, label: string, hint: string) {
    this.value = value;
    this.label = label;
    this.hint = hint;
  }
}

/**
 * Emulator-level settings, persisted with preferences and mirrored into
 * AppStorage so components can bind them with @StorageLink. load() must run
 * (once, early in boot) before the config generator reads the fields; the
 * setters write through to memory, AppStorage and the store in one call.
 *
 * AppStorage keys live under the 'settings.' prefix; they are seeded by
 * load() and only written through the setters below.
 */
export class AppSettings {
  /** [cpu] cpu_cycles: 'max' or a fixed cycles-per-ms number (engine range 50..2000000). */
  static cpuCycles: string = 'max';
  /** [mixer] nosound: engine applies it at boot only (restart to take effect). */
  static mute: boolean = false;
  /** Re-mount lastMountDir as C: on the next app boot (via [autoexec]). */
  static autoMount: boolean = false;
  /** Last folder successfully mounted as C: ('' = none). */
  static lastMountDir: string = '';

  private static store: preferences.Preferences | null = null;

  static readonly CPU_OPTIONS: CpuCycleOption[] = [
    new CpuCycleOption('max', '最大', '不限速，最快；老游戏可能跑得过快'),
    new CpuCycleOption('3000', '3000', '386SX 级，经典老游戏'),
    new CpuCycleOption('8000', '8000', '386DX-40 级'),
    new CpuCycleOption('20000', '20000', '486DX2 级'),
    new CpuCycleOption('50000', '50000', 'Pentium 级')
  ];

  static cpuHint(value: string): string {
    for (const opt of AppSettings.CPU_OPTIONS) {
      if (opt.value === value) {
        return opt.hint;
      }
    }
    return '';
  }

  /** Reads the persisted store once and seeds AppStorage from it. */
  static async load(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(ctx, STORE_NAME);
      AppSettings.store = store;
      const cycles: preferences.ValueType = store.getSync('cpuCycles', AppSettings.cpuCycles);
      if (typeof cycles === 'string') {
        AppSettings.cpuCycles = cycles;
      }
      const mute: preferences.ValueType = store.getSync('mute', AppSettings.mute);
      if (typeof mute === 'boolean') {
        AppSettings.mute = mute;
      }
      const autoMount: preferences.ValueType = store.getSync('autoMount', AppSettings.autoMount);
      if (typeof autoMount === 'boolean') {
        AppSettings.autoMount = autoMount;
      }
      const lastDir: preferences.ValueType = store.getSync('lastMountDir', AppSettings.lastMountDir);
      if (typeof lastDir === 'string') {
        AppSettings.lastMountDir = lastDir;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'load settings failed: %{public}s', err.message);
    }
    AppSettings.seedAppStorage();
  }

  static setCpuCycles(value: string): void {
    AppSettings.cpuCycles = value;
    AppStorage.setOrCreate('settings.cpuCycles', value);
    AppSettings.persist('cpuCycles', value);
  }

  static setMute(value: boolean): void {
    AppSettings.mute = value;
    AppStorage.setOrCreate('settings.mute', value);
    AppSettings.persist('mute', value);
  }

  static setAutoMount(value: boolean): void {
    AppSettings.autoMount = value;
    AppStorage.setOrCreate('settings.autoMount', value);
    AppSettings.persist('autoMount', value);
  }

  static setLastMountDir(value: string): void {
    AppSettings.lastMountDir = value;
    AppStorage.setOrCreate('settings.lastMountDir', value);
    AppSettings.persist('lastMountDir', value);
  }

  private static persist(key: string, value: preferences.ValueType): void {
    const store = AppSettings.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush().catch((error: BusinessError) => {
        hilog.error(0x0000, TAG, 'flush settings failed: %{public}s', error.message);
      });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'persist setting %{public}s failed: %{public}s', key, err.message);
    }
  }

  private static seedAppStorage(): void {
    AppStorage.setOrCreate('settings.cpuCycles', AppSettings.cpuCycles);
    AppStorage.setOrCreate('settings.mute', AppSettings.mute);
    AppStorage.setOrCreate('settings.autoMount', AppSettings.autoMount);
    AppStorage.setOrCreate('settings.lastMountDir', AppSettings.lastMountDir);
  }
}
