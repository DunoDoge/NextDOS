import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'NextDOS';
const PROBE_NAME: string = '.nextdos-probe';

/**
 * Manages the public download folder of this app ("Download/<bundleName>/").
 *
 * The folder is auto-created by DocumentViewPicker in DOWNLOAD mode: no UI is
 * shown, no permission is required, and the returned URI carries persistent
 * authorization, so the same folder can be re-used across app restarts.
 *
 * EXPORTS: MountFolder
 */
export class MountFolder {
  private static pickerUri: string = '';

  /** Returns the DOWNLOAD-mode directory URI (persistently authorized). */
  static async prepareMountUri(context: common.UIAbilityContext): Promise<string> {
    if (MountFolder.pickerUri !== '') {
      return MountFolder.pickerUri;
    }
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const result: Array<string> = await documentViewPicker.save(options);
    if (result.length === 0) {
      throw new Error('DOWNLOAD mode returned no directory URI');
    }
    MountFolder.pickerUri = result[0];
    hilog.info(0x0000, TAG, 'mount folder uri: %{public}s', MountFolder.pickerUri);
    return MountFolder.pickerUri;
  }

  /** Converts the directory URI to a real sandbox path (probe-file trick). */
  static async prepareMountDir(context: common.UIAbilityContext): Promise<string> {
    const uri: string = await MountFolder.prepareMountUri(context);
    const probePath: string = new fileUri.FileUri(uri + '/' + PROBE_NAME).path;
    return probePath.substring(0, probePath.length - PROBE_NAME.length - 1);
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
}
