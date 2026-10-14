import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MountRecord } from './MountFolder';

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
 * A consistent set of virtual NAT network parameters for the slirp backend,
 * ready to be written into the [ethernet] section. Plain class (not an
 * object literal) so it stays valid under ArkTS strict typing.
 */
export class NetworkParams {
  ip: string = '';
  netmask: string = '';
  gateway: string = '';
  dns: string = '';

  constructor(ip: string, netmask: string, gateway: string, dns: string) {
    this.ip = ip;
    this.netmask = netmask;
    this.gateway = gateway;
    this.dns = dns;
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
  /** Never mount Index.imeLayer on canvas taps: the system soft keyboard
   * stays down and text goes through the in-app KeyboardPanel instead.
   * Pure UI behavior, applied the moment it is set (no engine involvement). */
  static blockSoftKeyboard: boolean = false;
  /** Open the in-app KeyboardPanel docked (split view: the panel owns the
   * bottom half of the window and the canvas refits to the top half) instead
   * of floating translucently over the full canvas. Persisted choice; takes
   * effect on the next panel open or mode toggle, no engine involvement
   * beyond the canvas-size refit the resize itself triggers. */
  static keyboardDocked: boolean = false;
  /** Last folder successfully mounted as C: ('' = none). */
  static lastMountDir: string = '';
  /** Picker URI of lastMountDir whose persisted grant covers it ('' = none /
   * legacy download-folder mount). Kept beside the path because the URI is
   * what gets re-activated after an app restart (MountFolder.activateAccess). */
  static lastMountUri: string = '';
  /** Recent C: mount records, most recent first, capped at RECENT_MOUNT_MAX;
   * the settings sheet lists them for choosing the auto-mount target. */
  static recentMounts: MountRecord[] = [];
  /** Sandbox slot path of the last staged CD image ('' = none); the D:
   * [autoexec] mount line is written only while it is non-empty. */
  static lastCdImage: string = '';
  /** [ethernet] ne2000: emulated NE2000 card on slirp user-mode NAT (boot-time). */
  static netNe2000: boolean = false;
  /** [ethernet] tcp_port_forwards: raw engine rule text (host:guest, ranges). */
  static netTcpForwards: string = '';
  /** [ethernet] udp_port_forwards: raw engine rule text. */
  static netUdpForwards: string = '';
  /** [ipx] ipx: IPX-over-UDP multiplayer (boot-time). */
  static netIpx: boolean = false;
  /** Defaults for the virtual NAT LAN; slirp falls back to these as a whole
   * when the configured set is invalid, and so does this model layer.
   * Declared before the net* fields so their initializers can reuse them. */
  static readonly NET_DEFAULT_IP: string = '10.0.2.15';
  static readonly NET_DEFAULT_NETMASK: string = '255.255.255.0';
  static readonly NET_DEFAULT_GATEWAY: string = '10.0.2.2';
  static readonly NET_DEFAULT_DNS: string = '10.0.2.3';
  /** [ethernet] slirp_dhcp_start: the guest's own IP in the virtual NAT LAN. */
  static netIp: string = AppSettings.NET_DEFAULT_IP;
  /** [ethernet] slirp_netmask: subnet mask of the virtual NAT LAN. */
  static netNetmask: string = AppSettings.NET_DEFAULT_NETMASK;
  /** [ethernet] slirp_host: virtual gateway / DHCP service address. */
  static netGateway: string = AppSettings.NET_DEFAULT_GATEWAY;
  /** [ethernet] slirp_dns: virtual DNS server address. */
  static netDns: string = AppSettings.NET_DEFAULT_DNS;

  private static store: preferences.Preferences | null = null;

  /** Size cap of the recent-mount MRU list (settings sheet 挂载记录). */
  static readonly RECENT_MOUNT_MAX: number = 5;

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
      const blockIme: preferences.ValueType = store.getSync('blockSoftKeyboard', AppSettings.blockSoftKeyboard);
      if (typeof blockIme === 'boolean') {
        AppSettings.blockSoftKeyboard = blockIme;
      }
      const kbDocked: preferences.ValueType = store.getSync('keyboardDocked', AppSettings.keyboardDocked);
      if (typeof kbDocked === 'boolean') {
        AppSettings.keyboardDocked = kbDocked;
      }
      const lastDir: preferences.ValueType = store.getSync('lastMountDir', AppSettings.lastMountDir);
      if (typeof lastDir === 'string') {
        AppSettings.lastMountDir = lastDir;
      }
      const lastUri: preferences.ValueType = store.getSync('lastMountUri', AppSettings.lastMountUri);
      if (typeof lastUri === 'string') {
        AppSettings.lastMountUri = lastUri;
      }
      // The MRU list rides two parallel newline-joined strings (paths and
      // picker URIs) — no JSON, and neither value can ever contain a line
      // break. Entries with no URI left simply restore with uri=''.
      const mruDirs: preferences.ValueType = store.getSync('recentMountDirs', '');
      const mruUris: preferences.ValueType = store.getSync('recentMountUris', '');
      if (typeof mruDirs === 'string' && typeof mruUris === 'string') {
        AppSettings.recentMounts = AppSettings.decodeMountRecords(mruDirs, mruUris);
      }
      const lastCd: preferences.ValueType = store.getSync('lastCdImage', AppSettings.lastCdImage);
      if (typeof lastCd === 'string') {
        AppSettings.lastCdImage = lastCd;
      }
      const netNe2000: preferences.ValueType = store.getSync('netNe2000', AppSettings.netNe2000);
      if (typeof netNe2000 === 'boolean') {
        AppSettings.netNe2000 = netNe2000;
      }
      const netTcp: preferences.ValueType = store.getSync('netTcpForwards', AppSettings.netTcpForwards);
      if (typeof netTcp === 'string') {
        AppSettings.netTcpForwards = netTcp;
      }
      const netUdp: preferences.ValueType = store.getSync('netUdpForwards', AppSettings.netUdpForwards);
      if (typeof netUdp === 'string') {
        AppSettings.netUdpForwards = netUdp;
      }
      const netIpx: preferences.ValueType = store.getSync('netIpx', AppSettings.netIpx);
      if (typeof netIpx === 'boolean') {
        AppSettings.netIpx = netIpx;
      }
      const netIp: preferences.ValueType = store.getSync('netIp', AppSettings.netIp);
      if (typeof netIp === 'string') {
        AppSettings.netIp = netIp;
      }
      const netMask: preferences.ValueType = store.getSync('netNetmask', AppSettings.netNetmask);
      if (typeof netMask === 'string') {
        AppSettings.netNetmask = netMask;
      }
      const netGw: preferences.ValueType = store.getSync('netGateway', AppSettings.netGateway);
      if (typeof netGw === 'string') {
        AppSettings.netGateway = netGw;
      }
      const netDns: preferences.ValueType = store.getSync('netDns', AppSettings.netDns);
      if (typeof netDns === 'string') {
        AppSettings.netDns = netDns;
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

  static setBlockSoftKeyboard(value: boolean): void {
    AppSettings.blockSoftKeyboard = value;
    AppStorage.setOrCreate('settings.blockSoftKeyboard', value);
    AppSettings.persist('blockSoftKeyboard', value);
  }

  static setKeyboardDocked(value: boolean): void {
    AppSettings.keyboardDocked = value;
    AppStorage.setOrCreate('settings.keyboardDocked', value);
    AppSettings.persist('keyboardDocked', value);
  }

  static setLastMountDir(value: string): void {
    AppSettings.lastMountDir = value;
    AppStorage.setOrCreate('settings.lastMountDir', value);
    AppSettings.persist('lastMountDir', value);
  }

  static setLastMountUri(value: string): void {
    AppSettings.lastMountUri = value;
    AppStorage.setOrCreate('settings.lastMountUri', value);
    AppSettings.persist('lastMountUri', value);
  }

  /** Moves (or inserts) the folder to the front of the recent-mount MRU,
   * dropping a stale entry for the same path, and persists the list. The
   * AppStorage value is always a fresh array: V1 state observation only
   * fires on reassignment, never on in-place mutation. */
  static recordMount(dir: string, uri: string): void {
    const records: MountRecord[] = [new MountRecord(dir, uri)];
    for (let i = 0; i < AppSettings.recentMounts.length &&
      records.length < AppSettings.RECENT_MOUNT_MAX; i++) {
      const record: MountRecord = AppSettings.recentMounts[i];
      if (record.dir !== dir) {
        records.push(record);
      }
    }
    AppSettings.recentMounts = records;
    AppStorage.setOrCreate('settings.recentMounts', records);
    AppSettings.persistRecentMounts();
  }

  /** Drops one folder from the recent-mount MRU (settings sheet delete). */
  static removeRecentMount(dir: string): void {
    const records: MountRecord[] = [];
    for (let i = 0; i < AppSettings.recentMounts.length; i++) {
      const record: MountRecord = AppSettings.recentMounts[i];
      if (record.dir !== dir) {
        records.push(record);
      }
    }
    AppSettings.recentMounts = records;
    AppStorage.setOrCreate('settings.recentMounts', records);
    AppSettings.persistRecentMounts();
  }

  private static decodeMountRecords(dirsJoined: string, urisJoined: string): MountRecord[] {
    const dirs: string[] = dirsJoined.length > 0 ? dirsJoined.split('\n') : [];
    const uris: string[] = urisJoined.length > 0 ? urisJoined.split('\n') : [];
    const count: number = Math.min(dirs.length, uris.length);
    const records: MountRecord[] = [];
    for (let i = 0; i < count; i++) {
      if (dirs[i] !== '') {
        records.push(new MountRecord(dirs[i], uris[i]));
      }
    }
    return records;
  }

  private static persistRecentMounts(): void {
    const dirs: string[] = [];
    const uris: string[] = [];
    for (let i = 0; i < AppSettings.recentMounts.length; i++) {
      dirs.push(AppSettings.recentMounts[i].dir);
      uris.push(AppSettings.recentMounts[i].uri);
    }
    AppSettings.persist('recentMountDirs', dirs.join('\n'));
    AppSettings.persist('recentMountUris', uris.join('\n'));
  }

  static setLastCdImage(value: string): void {
    AppSettings.lastCdImage = value;
    AppStorage.setOrCreate('settings.lastCdImage', value);
    AppSettings.persist('lastCdImage', value);
  }

  static setNetNe2000(value: boolean): void {
    AppSettings.netNe2000 = value;
    AppStorage.setOrCreate('settings.netNe2000', value);
    AppSettings.persist('netNe2000', value);
  }

  static setNetTcpForwards(value: string): void {
    AppSettings.netTcpForwards = value;
    AppStorage.setOrCreate('settings.netTcpForwards', value);
    AppSettings.persist('netTcpForwards', value);
  }

  static setNetUdpForwards(value: string): void {
    AppSettings.netUdpForwards = value;
    AppStorage.setOrCreate('settings.netUdpForwards', value);
    AppSettings.persist('netUdpForwards', value);
  }

  static setNetIpx(value: boolean): void {
    AppSettings.netIpx = value;
    AppStorage.setOrCreate('settings.netIpx', value);
    AppSettings.persist('netIpx', value);
  }

  static setNetIp(value: string): void {
    AppSettings.netIp = value;
    AppStorage.setOrCreate('settings.netIp', value);
    AppSettings.persist('netIp', value);
  }

  static setNetNetmask(value: string): void {
    AppSettings.netNetmask = value;
    AppStorage.setOrCreate('settings.netNetmask', value);
    AppSettings.persist('netNetmask', value);
  }

  static setNetGateway(value: string): void {
    AppSettings.netGateway = value;
    AppStorage.setOrCreate('settings.netGateway', value);
    AppSettings.persist('netGateway', value);
  }

  static setNetDns(value: string): void {
    AppSettings.netDns = value;
    AppStorage.setOrCreate('settings.netDns', value);
    AppSettings.persist('netDns', value);
  }

  /** Free-text engine fields must not contain line breaks or they would
   * split (or inject) a config line. Applied when the config is generated,
   * not when the value is typed, so multi-rule values like "21 80 443" keep
   * their interior spaces while being edited. The app does no other
   * validation; the engine parses the rule grammar itself. */
  static sanitizeLine(value: string): string {
    return value.split('\r').join(' ').split('\n').join(' ').trim();
  }

  /** True when the text is a dotted-quad IPv4 address (each octet 0..255). */
  static isValidIPv4(value: string): boolean {
    const text: string = value.trim();
    const parts: string[] = text.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i];
      if (part.length === 0 || part.length > 3) {
        return false;
      }
      for (let j = 0; j < part.length; j++) {
        const code: number = part.charCodeAt(j);
        if (code < 48 || code > 57) {
          return false;
        }
      }
      const octet: number = Number.parseInt(part, 10);
      if (octet < 0 || octet > 255) {
        return false;
      }
    }
    return true;
  }

  private static ipv4ToInt(addr: string): number {
    const parts: string[] = addr.split('.');
    let value: number = 0;
    for (let i = 0; i < 4; i++) {
      value = (value * 256) + Number.parseInt(parts[i], 10);
    }
    return value;
  }

  /** Resolves the four virtual-NAT parameters, falling back to the slirp
   * defaults as a whole when any field is not a valid IPv4 address or the
   * DHCP address falls outside `gateway & netmask`. This mirrors the
   * engine's own check (ethernet_slirp.cpp), so the generated config always
   * matches the network slirp actually starts on. */
  static resolvedNetworkParams(): NetworkParams {
    const ip: string = AppSettings.netIp.trim();
    const netmask: string = AppSettings.netNetmask.trim();
    const gateway: string = AppSettings.netGateway.trim();
    const dns: string = AppSettings.netDns.trim();
    const allValid: boolean = AppSettings.isValidIPv4(ip) &&
      AppSettings.isValidIPv4(netmask) &&
      AppSettings.isValidIPv4(gateway) &&
      AppSettings.isValidIPv4(dns);
    if (allValid) {
      const mask: number = AppSettings.ipv4ToInt(netmask);
      if ((AppSettings.ipv4ToInt(ip) & mask) === (AppSettings.ipv4ToInt(gateway) & mask)) {
        return new NetworkParams(ip, netmask, gateway, dns);
      }
    }
    return new NetworkParams(AppSettings.NET_DEFAULT_IP, AppSettings.NET_DEFAULT_NETMASK,
      AppSettings.NET_DEFAULT_GATEWAY, AppSettings.NET_DEFAULT_DNS);
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
    AppStorage.setOrCreate('settings.blockSoftKeyboard', AppSettings.blockSoftKeyboard);
    AppStorage.setOrCreate('settings.keyboardDocked', AppSettings.keyboardDocked);
    AppStorage.setOrCreate('settings.lastMountDir', AppSettings.lastMountDir);
    AppStorage.setOrCreate('settings.lastMountUri', AppSettings.lastMountUri);
    AppStorage.setOrCreate('settings.recentMounts', AppSettings.recentMounts);
    AppStorage.setOrCreate('settings.lastCdImage', AppSettings.lastCdImage);
    AppStorage.setOrCreate('settings.netNe2000', AppSettings.netNe2000);
    AppStorage.setOrCreate('settings.netTcpForwards', AppSettings.netTcpForwards);
    AppStorage.setOrCreate('settings.netUdpForwards', AppSettings.netUdpForwards);
    AppStorage.setOrCreate('settings.netIpx', AppSettings.netIpx);
    AppStorage.setOrCreate('settings.netIp', AppSettings.netIp);
    AppStorage.setOrCreate('settings.netNetmask', AppSettings.netNetmask);
    AppStorage.setOrCreate('settings.netGateway', AppSettings.netGateway);
    AppStorage.setOrCreate('settings.netDns', AppSettings.netDns);
  }
}
