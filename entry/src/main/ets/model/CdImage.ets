import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'NextDOS';
// Cue sheets are text tables of a few KB; anything larger is a mis-picked
// binary and would be read into memory whole, so cap the cue read.
const CUE_MAX_BYTES: number = 1024 * 1024;
// ISO9660 'CD001' candidate positions the engine's CanReadPVD probes:
// 16 * sector_size + 1 for the 2048-byte layout and for the 2352-byte
// raw layouts (MODE1 seeks +16, MODE2 +24). All three fit in one read
// starting at 32769.
const PVD_PROBE_START: number = 32769;
const PVD_PROBE_LENGTH: number = 4893;
// 'CD001' relative offsets inside that read: 32769, 37649, 37657.
const PVD_OFFSETS: number[] = [0, 4880, 4888];

/**
 * Result of a staged CD image: the sandbox slot path that is mounted as
 * the guest D: drive, the original display name, and what the non-blocking
 * pre-check could say about it. pvdOk is only meaningful for .iso/.bin/.img
 * (ISO9660 PVD sniffed); cue mounts are judged by the guest alone.
 */
export class CdStaged {
  path: string = '';
  isCue: boolean = false;
  name: string = '';
  pvdOk: boolean = false;
}

/** A picked but not-yet-copied image: exists so the UI can show its copy
 * toast after the picker closed instead of before it opened (a pre-picker
 * toast would survive a cancelled selection and lie about a copy). */
export class CdPick {
  uri: string = '';
  name: string = '';
  realPath: string = '';
}

/**
 * Stages a user-picked CD image into a fixed ASCII slot directory
 * (filesDir/cdrom/) so the running guest can mount it as D: with a plain
 * `mount d <slot> -t iso` injection: typeIntoGuest can only deliver
 * printable ASCII, so Chinese paths can never reach the guest directly and
 * the engine needs a real host path to open.
 *
 * The slot is byte-flat: one cdrom.<ext> image plus, for cue sheets, the
 * referenced track files under their cue-decoded names. The cue itself is
 * RE-ENCODED to UTF-8, never byte-copied: the engine reads the cue as raw
 * bytes and probes sibling existence with those same bytes, while every
 * file the platform creates carries UTF-8 names — a GBK cue copied
 * verbatim would reference names whose bytes never exist on disk and the
 * mount would fail inside the guest with no app-side error.
 *
 * EXPORTS: CdStaged, CdPick, CdImage
 */
export class CdImage {
  /** Runs the document picker only; null means the user cancelled (no
   * staging, no error). Copying lives in stage() so the UI shows its
   * progress toast between the picker closing and the copy starting. */
  static async pick(ctx: common.UIAbilityContext): Promise<CdPick | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['光盘镜像(.iso/.cue/.bin/.img)|.iso,.cue,.bin,.img'];
    const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await documentViewPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const resolved = new fileUri.FileUri(uris[0]);
    const pick: CdPick = new CdPick();
    pick.uri = uris[0];
    pick.name = resolved.name;
    pick.realPath = resolved.path;
    return pick;
  }

  /** Copies the picked image into the slot and returns the mount-ready
   * result. Throws Chinese-guidance errors on unsupported extensions and
   * staging failures; the caller wipes half-copied slot files on error. */
  static async stage(picked: CdPick, ctx: common.UIAbilityContext): Promise<CdStaged> {
    const lower: string = picked.name.toLowerCase();
    const slotDir: string = CdImage.ensureSlotDir(ctx);
    if (lower.endsWith('.cue')) {
      return CdImage.stageCue(picked.uri, picked.realPath, picked.name, slotDir);
    }
    if (lower.endsWith('.iso') || lower.endsWith('.bin') || lower.endsWith('.img')) {
      return CdImage.stageBinary(picked.uri, picked.name, slotDir);
    }
    throw new Error('不支持的光盘镜像格式，请选择 .iso/.cue/.bin/.img 文件');
  }

  /** Throws when the persisted slot path no longer exists, so the caller
   * can clear the stored entry instead of auto-mounting a phantom D:. */
  static verifySlot(path: string): void {
    try {
      if (fs.accessSync(path)) {
        return;
      }
    } catch (error) {
      const err = error as BusinessError;
      throw new Error('槽位校验失败: ' + err.message);
    }
    throw new Error('槽位文件不存在: ' + path);
  }

  /** Deletes every staged file and the slot directory. Only call this
   * after the unmount keystrokes finished injecting: the slot must stop
   * existing no earlier than D: disappears from the guest. */
  static clearSlot(ctx: common.UIAbilityContext): void {
    const dir: string = ctx.filesDir + '/cdrom';
    const entries: string[] = fs.listFileSync(dir);
    for (let i = 0; i < entries.length; i++) {
      let entry: string = entries[i];
      if (entry.startsWith('/')) {
        entry = entry.substring(1);
      }
      fs.unlinkSync(dir + '/' + entry);
    }
    fs.rmdirSync(dir);
  }

  private static ensureSlotDir(ctx: common.UIAbilityContext): string {
    const dir: string = ctx.filesDir + '/cdrom';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  /** Copies the image into the slot and sniffs the ISO9660 PVD on the copy.
   * The sniff is a toast hint only: it never blocks the mount, the engine
   * keeps the final word (and also accepts layouts this probe skips). */
  private static async stageBinary(uri: string, name: string, slotDir: string): Promise<CdStaged> {
    const lower: string = name.toLowerCase();
    const slotPath: string = slotDir + '/cdrom' + lower.substring(lower.lastIndexOf('.'));
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      await fs.copyFile(src.fd, slotPath);
    } finally {
      fs.closeSync(src);
    }
    const staged: CdStaged = new CdStaged();
    staged.path = slotPath;
    staged.isCue = false;
    staged.name = name;
    staged.pvdOk = CdImage.probePvd(slotPath);
    return staged;
  }

  private static probePvd(slotPath: string): boolean {
    try {
      // A single readSync from a freshly opened fd: ReadOptions.offset
      // semantics (absolute vs filePointer-relative) coincide at pointer 0,
      // so one read covers all three candidate positions unambiguously.
      const file = fs.openSync(slotPath, fs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(PVD_PROBE_LENGTH);
        const bytesRead: number = fs.readSync(file.fd, buf, { offset: PVD_PROBE_START });
        const bytes: Uint8Array = new Uint8Array(buf);
        for (let i = 0; i < PVD_OFFSETS.length; i++) {
          if (CdImage.hasCd001(bytes, PVD_OFFSETS[i], bytesRead)) {
            return true;
          }
        }
        return false;
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      // The sniff must never fail the mount: an unreadable file just gets
      // the "format uncertain" toast and the engine decides.
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'cd pvd probe failed: %{public}s', err.message);
      return false;
    }
  }

  private static hasCd001(bytes: Uint8Array, at: number, bytesRead: number): boolean {
    if (bytesRead < at + 5) {
      return false;
    }
    return bytes[at] === 67 && bytes[at + 1] === 68 && bytes[at + 2] === 48 && bytes[at + 3] === 48 &&
      bytes[at + 4] === 49;
  }

  /** Cue branch: read + decode the sheet, copy the referenced track files
   * under their decoded names, then write the sheet back as UTF-8 text so
   * the engine's raw-byte lookups hit the copied names. */
  private static async stageCue(uri: string, realPath: string, name: string, slotDir: string): Promise<CdStaged> {
    const text: string = CdImage.readAndDecodeCue(uri);
    const fileNames: string[] = CdImage.parseCueFileNames(text);
    if (fileNames.length === 0) {
      throw new Error('不是有效的 cue 文件：未找到 FILE 音轨条目');
    }
    const cueDir: string = realPath.substring(0, realPath.lastIndexOf('/'));
    const slotPath: string = slotDir + '/cdrom.cue';
    for (let i = 0; i < fileNames.length; i++) {
      await CdImage.copyCueSibling(cueDir, slotDir, fileNames[i]);
    }
    // writeSync(fd, string) encodes UTF-8: the slot cue becomes UTF-8,
    // byte-identical to a pure-ASCII input and re-encoded for GBK input.
    const file = fs.openSync(slotPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    const staged: CdStaged = new CdStaged();
    staged.path = slotPath;
    staged.isCue = true;
    staged.name = name;
    staged.pvdOk = false;
    return staged;
  }

  /** Decodes the whole cue sheet: UTF-8 first, gb18030 (GBK superset) when
   * the bytes contain replacement characters, keeping Chinese FILE names
   * intact for the re-encoded slot copy. */
  private static readAndDecodeCue(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      if (stat.size > CUE_MAX_BYTES) {
        throw new Error('cue 文件过大，可能不是 cue 文件');
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size > 0 ? stat.size : 1);
      const bytesRead: number = fs.readSync(file.fd, buf, { offset: 0 });
      const bytes: Uint8Array = new Uint8Array(buf, 0, bytesRead);
      const utf8Text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      if (utf8Text.indexOf('\uFFFD') < 0) {
        return utf8Text;
      }
      return util.TextDecoder.create('gb18030').decodeToString(bytes);
    } finally {
      fs.closeSync(file);
    }
  }

  /** Extracts every FILE entry's name, mirroring the engine's cue parse:
   * the command word matches case-insensitively (GetCueKeyword upper-cases
   * the token before comparing, so `file`/`File` are legal cue commands),
   * then the next field is either quoted (spaces allowed, up to the
   * closing quote) or a bare token. */
  private static parseCueFileNames(text: string): string[] {
    const names: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      let pos: number = 0;
      while (pos < line.length && CdImage.isSpace(line.charAt(pos))) {
        pos++;
      }
      let cmdEnd: number = pos;
      while (cmdEnd < line.length && !CdImage.isSpace(line.charAt(cmdEnd))) {
        cmdEnd++;
      }
      if (line.substring(pos, cmdEnd).toUpperCase() !== 'FILE') {
        continue;
      }
      const fileName: string = CdImage.cueFileName(line, cmdEnd);
      if (fileName !== '') {
        names.push(fileName);
      }
    }
    return names;
  }

  /** GetCueString equivalent for one cue line: skips spaces, then reads a
   * quoted field (to the next quote) or an unquoted one (to the next
   * space). An unterminated quote yields '' and drops the entry. */
  private static cueFileName(line: string, from: number): string {
    let pos: number = from;
    while (pos < line.length && CdImage.isSpace(line.charAt(pos))) {
      pos++;
    }
    if (pos >= line.length) {
      return '';
    }
    if (line.charAt(pos) === '"') {
      const end: number = line.indexOf('"', pos + 1);
      if (end < 0) {
        return '';
      }
      return line.substring(pos + 1, end);
    }
    let end: number = pos;
    while (end < line.length && !CdImage.isSpace(line.charAt(end))) {
      end++;
    }
    return line.substring(pos, end);
  }

  private static isSpace(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\r';
  }

  /** Copies one referenced track file into the slot. The slot target name
   * is always the cue-decoded name: the engine probes siblings with the
   * cue's raw bytes through a case-sensitive access() (GetRealFileName —
   * its case-insensitive resolution only runs on mounted DOS drives), so
   * the slot file must carry exactly the cued spelling even when the
   * on-disk source differs. The case-insensitive listing below bridges
   * that gap between the literal join and the engine's byte probe. */
  private static async copyCueSibling(cueDir: string, slotDir: string, fileName: string): Promise<void> {
    if (fileName.indexOf('/') >= 0 || fileName.indexOf('\\') >= 0) {
      throw new Error('cue 引用了子目录中的音轨文件（' + fileName + '），当前版本不支持，' +
        '请把 cue 与音轨文件放在同一目录后重试');
    }
    const targetPath: string = slotDir + '/' + fileName;
    let sourceResolved: string = '';
    try {
      const sourcePath: string = cueDir + '/' + fileName;
      if (fs.accessSync(sourcePath)) {
        sourceResolved = sourcePath;
      } else {
        // Literal join missed: fall back to a case-insensitive listing and
        // keep the on-disk spelling as the copy source.
        const entries: string[] = fs.listFileSync(cueDir);
        for (let i = 0; i < entries.length; i++) {
          let entry: string = entries[i];
          if (entry.startsWith('/')) {
            entry = entry.substring(1);
          }
          if (entry.toLowerCase() === fileName.toLowerCase()) {
            sourceResolved = cueDir + '/' + entry;
            break;
          }
        }
      }
    } catch (error) {
      // Picker authorization covers only the picked cue URI; a sibling
      // read that fails on permissions must reach the same guidance, not
      // a raw errno message.
      const err = error as BusinessError;
      hilog.warn(0x0000, TAG, 'cue sibling %{public}s unreadable: %{public}s', fileName, err.message);
      throw new Error('无法读取 cue 引用的音轨文件 ' + fileName + '：请把 cue 与音轨文件放入' +
        '应用下载目录 Download/<应用名>/ 后重试');
    }
    if (sourceResolved === '') {
      throw new Error('找不到 cue 引用的音轨文件 ' + fileName + '：请确认它与 cue 在同一目录（注意大小写），' +
        '或将其放入应用下载目录 Download/<应用名>/ 后重试');
    }
    await fs.copyFile(sourceResolved, targetPath);
  }
}
