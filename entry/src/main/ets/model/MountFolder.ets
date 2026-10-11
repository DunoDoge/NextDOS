import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker, fileIo, fileUri, fileShare } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'NextDOS';
const PROBE_NAME: string = '.nextdos-probe';

/**
 * One remembered C: mount target: the real sandbox path the engine mounts
 * and the picker URI whose grant covers it. The URI is what persists (see
 * persistAccess/activateAccess) — the path alone becomes inaccessible once
 * the picker's temporary authorization expires.
 */
export class MountRecord {
  dir: string = '';
  uri: string = '';

  constructor(dir: string, uri: string) {
    this.dir = dir;
    this.uri = uri;
  }
}

/**
 * Lets the user mount ANY accessible folder as the emulated C: drive via the
 * system folder picker (DocumentSelectMode.FOLDER).
 *
 * A picked folder only carries a temporary read/write grant that expires when
 * the app leaves the foreground, so it is persisted right away with
 * fileShare.persistPermission and re-activated on demand (app/device restart)
 * with fileShare.activatePermission — both need the
 * ohos.permission.FILE_ACCESS_PERSIST declaration. All fileShare calls are
 * best-effort: a failed persistence still mounts for this session, and
 * verifyAccess stays the final judge of reachability.
 *
 * EXPORTS: MountRecord, MountFolder
 */
export class MountFolder {
  /**
   * Opens the folder picker and returns the picked folder (null = cancelled).
   * The grant is persisted immediately so the folder can be auto-mounted
   * again after an app restart.
   */
  static async pickMountFolder(context: common.UIAbilityContext): Promise<MountRecord | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const result: Array<string> = await documentViewPicker.select(options);
    if (result.length === 0) {
      return null;
    }
    const uri: string = result[0];
    const dir: string = new fileUri.FileUri(uri).path;
    hilog.info(0x0000, TAG, 'mount folder picked: %{public}s', dir);
    await MountFolder.persistAccess(uri);
    return new MountRecord(dir, uri);
  }

  /** Read+write policy list for one URI, shared by persist/activate. */
  private static grantPolicies(uri: string): fileShare.PolicyInfo[] {
    const policy: fileShare.PolicyInfo = {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    };
    return [policy];
  }

  /** Persists the picker grant (read+write) so it survives app restarts.
   * Best-effort: a failure only costs the auto-mount restore, never the
   * current session's mount. */
  static async persistAccess(uri: string): Promise<void> {
    try {
      await fileShare.persistPermission(MountFolder.grantPolicies(uri));
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'persist folder grant failed: %{public}s', err.message);
    }
  }

  /** Re-enables a persisted grant after an app/device restart (persisted
   * grants are stored inactive; docs advise activating only what is about
   * to be used). Best-effort: verifyAccess decides reachability next. */
  static async activateAccess(uri: string): Promise<void> {
    if (uri === '') {
      return;
    }
    try {
      await fileShare.activatePermission(MountFolder.grantPolicies(uri));
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'activate folder grant failed: %{public}s', err.message);
    }
  }

  /** Verifies read/write access to the folder by creating a probe file. */
  static verifyAccess(dir: string): void {
    const probePath: string = dir + '/' + PROBE_NAME;
    try {
      const file = fileIo.openSync(probePath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, 'nextdos');
      fileIo.closeSync(file);
      fileIo.unlinkSync(probePath);
    } catch (error) {
      const err = error as BusinessError;
      throw new Error('folder not writable: ' + err.message);
    }
  }

  /** Whether every character is printable ASCII (the range the DOS shell
   * round-trips through its code page unchanged, and the only range the
   * keyboard-injection path can map to keycodes). Callers use it to decide
   * between injecting a mount command into the running guest and applying
   * it through the [autoexec] config via an engine restart. */
  static isTypeable(text: string): boolean {
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x20 || code > 0x7e) {
        return false;
      }
    }
    return true;
  }
}
