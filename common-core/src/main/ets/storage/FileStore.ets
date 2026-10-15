import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

export class FileStore {
  private static dir: string = '';

  static initialize(context: common.UIAbilityContext): void {
    FileStore.dir = context.filesDir;
  }

  static saveJson(name: string, value: Object): boolean {
    const path = FileStore.pathOf(name);
    if (path.length === 0) {
      return false;
    }
    try {
      fileIo.writeTextSync(path, JSON.stringify(value));
      return true;
    } catch (error) {
      return false;
    }
  }

  static loadJson(name: string): Record<string, Object> | null {
    const path = FileStore.pathOf(name);
    if (path.length === 0 || !FileStore.exists(name)) {
      return null;
    }
    try {
      const text = fileIo.readTextSync(path);
      const parsed = JSON.parse(text) as Record<string, Object>;
      return parsed === null ? null : parsed;
    } catch (error) {
      return null;
    }
  }

  static exists(name: string): boolean {
    const path = FileStore.pathOf(name);
    if (path.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  static remove(name: string): boolean {
    const path = FileStore.pathOf(name);
    if (path.length === 0 || !FileStore.exists(name)) {
      return false;
    }
    try {
      fileIo.unlinkSync(path);
      return true;
    } catch (error) {
      return false;
    }
  }

  private static pathOf(name: string): string {
    if (FileStore.dir.length === 0 || !FileStore.isSafeName(name)) {
      return '';
    }
    return `${FileStore.dir}/${name}.json`;
  }

  private static isSafeName(name: string): boolean {
    if (name.length === 0 || name.length > 64) {
      return false;
    }
    for (let i = 0; i < name.length; i++) {
      const code = name.charCodeAt(i);
      const isLower = code >= 97 && code <= 122;
      const isUpper = code >= 65 && code <= 90;
      const isDigit = code >= 48 && code <= 57;
      const isDash = code === 45 || code === 95;
      if (!isLower && !isUpper && !isDigit && !isDash) {
        return false;
      }
    }
    return true;
  }
}
