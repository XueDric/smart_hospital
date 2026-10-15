import { mediaquery } from '@kit.ArkUI';
import { KeyValueStore } from '../storage/KeyValueStore';

export enum ThemeMode {
  AUTO = 'auto',
  LIGHT = 'light',
  DARK = 'dark'
}

const KEY_THEME_MODE: string = 'theme_mode';

export class ThemePalette {
  primary: string = '#00A9A7';
  primaryDark: string = '#007F7D';
  primarySoft: string = '#DFF5F3';
  background: string = '#F3F8F7';
  surface: string = '#FFFFFF';
  surfaceAlt: string = '#EAF3F2';
  text: string = '#193331';
  textSecondary: string = '#5F7371';
  border: string = '#D6E4E2';
  danger: string = '#C83B3B';
  dangerSoft: string = '#FCE8E8';
  warning: string = '#A35A00';
  warningSoft: string = '#FFF1D9';
  success: string = '#147A55';
  successSoft: string = '#DFF3E9';
  info: string = '#315B96';
  infoSoft: string = '#E7EFFB';
  disabled: string = '#AAB8B6';
  navBackground: string = '#193331';
  navText: string = '#FFFFFF';

  static light(): ThemePalette {
    return new ThemePalette();
  }

  static dark(): ThemePalette {
    const palette = new ThemePalette();
    palette.primaryDark = '#4FD8D6';
    palette.primarySoft = '#0E3B39';
    palette.background = '#101817';
    palette.surface = '#1A2624';
    palette.surfaceAlt = '#22302E';
    palette.text = '#E6F1EF';
    palette.textSecondary = '#9DB4B1';
    palette.border = '#354744';
    palette.danger = '#D96A6A';
    palette.dangerSoft = '#3A1F1F';
    palette.warning = '#D99A4E';
    palette.warningSoft = '#3A2E18';
    palette.success = '#58B98F';
    palette.successSoft = '#143528';
    palette.info = '#7FA8DC';
    palette.infoSoft = '#1B2C42';
    palette.disabled = '#5C6E6C';
    palette.navBackground = '#0C1514';
    palette.navText = '#E6F1EF';
    return palette;
  }
}

export class ThemeManager {
  private static instance: ThemeManager = new ThemeManager();
  private static readonly lightPalette: ThemePalette = ThemePalette.light();
  private static readonly darkPalette: ThemePalette = ThemePalette.dark();
  private mode: ThemeMode = ThemeMode.AUTO;
  private systemDark: boolean = false;
  private onChange?: () => void;
  private mediaListener?: mediaquery.MediaQueryListener;

  static getInstance(): ThemeManager {
    return ThemeManager.instance;
  }

  initialize(): void {
    this.mode = ThemeManager.toMode(KeyValueStore.getString(KEY_THEME_MODE, ThemeMode.AUTO));
    if (this.mediaListener === undefined) {
      this.mediaListener = mediaquery.matchMediaSync('(prefers-color-scheme: dark)');
      this.systemDark = this.mediaListener.matches;
      this.mediaListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.systemDark = result.matches;
        if (this.mode === ThemeMode.AUTO) {
          this.notify();
        }
      });
    }
  }

  getMode(): ThemeMode {
    return this.mode;
  }

  setMode(mode: ThemeMode): void {
    if (this.mode === mode) {
      return;
    }
    this.mode = mode;
    KeyValueStore.putString(KEY_THEME_MODE, mode);
    this.notify();
  }

  isDark(): boolean {
    if (this.mode === ThemeMode.LIGHT) {
      return false;
    }
    if (this.mode === ThemeMode.DARK) {
      return true;
    }
    return this.systemDark;
  }

  palette(): ThemePalette {
    return this.isDark() ? ThemeManager.darkPalette : ThemeManager.lightPalette;
  }

  setOnChange(callback?: () => void): void {
    this.onChange = callback;
  }

  private notify(): void {
    if (this.onChange !== undefined) {
      this.onChange();
    }
  }

  private static toMode(value: string): ThemeMode {
    if (value === ThemeMode.LIGHT) {
      return ThemeMode.LIGHT;
    }
    if (value === ThemeMode.DARK) {
      return ThemeMode.DARK;
    }
    return ThemeMode.AUTO;
  }
}
