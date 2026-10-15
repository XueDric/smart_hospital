import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME: string = 'smart_hospital_kv';

export class KeyValueStore {
  private static store?: preferences.Preferences;

  static initialize(context: common.UIAbilityContext): void {
    if (KeyValueStore.store === undefined) {
      KeyValueStore.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    }
  }

  static getString(key: string, defaultValue: string): string {
    if (KeyValueStore.store === undefined) {
      return defaultValue;
    }
    const value = KeyValueStore.store.getSync(key, defaultValue);
    return typeof value === 'string' ? value : defaultValue;
  }

  static getNumber(key: string, defaultValue: number): number {
    if (KeyValueStore.store === undefined) {
      return defaultValue;
    }
    const value = KeyValueStore.store.getSync(key, defaultValue);
    return typeof value === 'number' ? value : defaultValue;
  }

  static getBool(key: string, defaultValue: boolean): boolean {
    if (KeyValueStore.store === undefined) {
      return defaultValue;
    }
    const value = KeyValueStore.store.getSync(key, defaultValue);
    return typeof value === 'boolean' ? value : defaultValue;
  }

  static putString(key: string, value: string): void {
    if (KeyValueStore.store !== undefined) {
      KeyValueStore.store.putSync(key, value);
      KeyValueStore.flush();
    }
  }

  static putNumber(key: string, value: number): void {
    if (KeyValueStore.store !== undefined) {
      KeyValueStore.store.putSync(key, value);
      KeyValueStore.flush();
    }
  }

  static putBool(key: string, value: boolean): void {
    if (KeyValueStore.store !== undefined) {
      KeyValueStore.store.putSync(key, value);
      KeyValueStore.flush();
    }
  }

  static remove(key: string): void {
    if (KeyValueStore.store !== undefined) {
      KeyValueStore.store.deleteSync(key);
      KeyValueStore.flush();
    }
  }

  private static flush(): void {
    if (KeyValueStore.store !== undefined) {
      KeyValueStore.store.flush().catch(() => {
      });
    }
  }
}
