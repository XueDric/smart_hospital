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

/**
 * 主题状态（评审 P2-11：切换主题不再"整树重建"）。
 *
 * ## 改之前
 * `AppColor.*` 是**静态 getter**：读一次拿一个颜色字符串，ArkUI 不知道它跟任何状态有关，
 * 于是切主题只能靠 `entry/src/main/ets/pages/Index.ets` 里 `themeTick % 2` 的奇偶分支
 * （`Column` ↔ `Row` 交替）**把整棵页面树拆了重建**，靠"build 重新执行一遍"重新取色。代价：
 * 页面状态全丢（滚动位置、输入框内容、在途请求的回调）、重建瞬间闪烁、路由栈被重置 ——
 * 切一次主题约等于"重启一次界面"。
 *
 * ## 改之后
 * `ThemeManager` 标成 `@ObservedV2`，并加一个 `@Trace` 的 `paletteVersion`；`palette()`
 * 读它一下。任何在 `build()` 里读过 `AppColor.xxx` 的组件，构建期就与该状态建立了依赖；
 * 版本号一变，**只有真正引用到颜色的属性**被重新求值，页面树、状态、路由都不动。
 *
 * 前提：颜色必须在 `build()` 里读。若有组件把颜色缓进成员变量、或在 `aboutToAppear`
 * 里算好再用，它不会跟着变 —— 这也是本仓 `AppColor` 坚持 getter 形态、1312 处调用
 * 全部内联读（无一处赋值给字段）的原因。改这些调用点前先想清楚这一点。
 */
@ObservedV2
export class ThemeManager {
  private static instance: ThemeManager = new ThemeManager();
  private static readonly lightPalette: ThemePalette = ThemePalette.light();
  private static readonly darkPalette: ThemePalette = ThemePalette.dark();
  private mode: ThemeMode = ThemeMode.AUTO;
  private systemDark: boolean = false;
  private onChange?: () => void;
  private mediaListener?: mediaquery.MediaQueryListener;
  /** 主题版本号：唯一被 ArkUI 追踪的响应式字段，见类注释。 */
  @Trace private paletteVersion: number = 0;

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
    /*
     * ⚠ 这一段是响应式的**唯一入口**，但**它目前还不足以让整页重绘**。
     *
     * 事实（2026-10-18 三端联调实测记录，见 docs/联调记录-2026-10-18.md BUG-2）：
     *   - 上一版这里写的是**裸读** `this.paletteVersion;`；
     *   - 改成"版本号参与取值"（下面的 `tick >= 0`）后，插桩日志证明 setMode 之后
     *     `palette()` 返回的确实是新配色（bg #101817 / surface #1A2624 / text #E6F1EF），
     *     但**页面上已画出来的颜色仍然不变**，离开页面再回来才正确；
     *   - 也就是说依赖登记发生在 palette() 里，而 `AppColor.X` 是 static getter，
     *    调用它的组件属性并不会因此被标记为依赖。
     *
     * 所以本改动只把"读取"做实（不再靠可能被优化掉的裸读），不宣称修好 BUG-2。
     * 真正的修法需要让颜色来源成为组件可观察状态：
     *   ① 把主题版本放进 `AppStorageV2`，页面用 `@Monitor` 订阅后触发重绘；或
     *   ② 让 `AppColor` 变成 `@ObservedV2` 实例的属性，组件直接读实例字段。
     */
    const tick = this.paletteVersion;
    const dark = this.isDark();
    if (dark && tick >= 0) {
      return ThemeManager.darkPalette;
    }
    return ThemeManager.lightPalette;
  }

  setOnChange(callback?: () => void): void {
    this.onChange = callback;
  }

  private notify(): void {
    // 先推进响应式版本，再回调非 UI 监听（导出、埋点等）。
    this.paletteVersion = this.paletteVersion + 1;
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
