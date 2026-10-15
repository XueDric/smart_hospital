# 智慧医院客户端设计规范（DESIGN-SPEC）

> 适用范围：鸿蒙端（`common-core` / `feature-patient` / `feature-doctor` / `feature-admin` / `entry`）与 Android 患者端（`android-patient`）。
> 维护者：角色 C（公共模块与设计规范）。最后更新：2026-10-14。

---

## 1. 红线（必须遵守）

1. **颜色单一来源**：所有颜色必须取自 `common-core/src/main/ets/ui/Theme.ets` 的 `AppColor`。页面、组件内**禁止出现 `'#RRGGBB'` 字面量**。
2. **尺寸与字号单一来源**：间距走 `AppSize`，字号走 `AppText`，同样禁止字面量。
3. **公共组件优先**：`AppButton / PageHeader / SectionTitle / InfoBanner / EmptyState / LoadingBlock / StatusChip / FieldLabel / BottomNav` 已有实现时，禁止在页面里重写一份样式。
4. **可点击元素热区 ≥ 40vp**（`AppSize.TOUCH_MIN`）；图标按钮不足 40vp 时必须用 `constraintSize({ minHeight })` 或透明容器补齐。
5. **深浅双模式必须同时可验证**：新增任何颜色槽位，必须同时给出浅色与深色取值，否则深色模式下会出现"黑底黑字"。
6. **页面状态四态齐备**：每个数据页至少覆盖 加载中 / 空 / 错误 / 有数据 四种表现。

> 当前状态：全仓硬编码色值 0 处、硬编码字号 0 处、小于 40vp 的按钮热区 0 处（2026-10-14 全量扫描核对）。

---

## 2. 色彩系统（`AppColor`）

色槽由 `ThemeManager.palette()` 提供，`AppColor` 以静态 getter 暴露，**调用点写法不变、自动跟随深浅模式**。

| 语义槽 | 用途 | 浅色（Light） | 深色（Dark） |
|---|---|---|---|
| `PRIMARY` | 主按钮底、主强调 | `#00A9A7` | `#00A9A7` |
| `PRIMARY_DARK` | 主色上的文字、选中态文字 | `#007F7D` | `#4FD8D6` |
| `PRIMARY_SOFT` | 主色浅底（次按钮、选中胶囊） | `#DFF5F3` | `#0E3B39` |
| `BACKGROUND` | 页面底 | `#F3F8F7` | `#101817` |
| `SURFACE` | 卡片、底栏、弹层 | `#FFFFFF` | `#1A2624` |
| `SURFACE_ALT` | 输入框底、分段控件底 | `#EAF3F2` | `#22302E` |
| `TEXT` | 主文字 | `#193331` | `#E6F1EF` |
| `TEXT_SECONDARY` | 次要文字、说明 | `#5F7371` | `#9DB4B1` |
| `BORDER` | 分隔线、描边 | `#D6E4E2` | `#354744` |
| `DANGER` / `DANGER_SOFT` | 错误、危险征象 | `#C83B3B` / `#FCE8E8` | `#D96A6A` / `#3A1F1F` |
| `WARNING` / `WARNING_SOFT` | 警告（含明文 HTTP 提示） | `#A35A00` / `#FFF1D9` | `#D99A4E` / `#3A2E18` |
| `SUCCESS` / `SUCCESS_SOFT` | 成功 | `#147A55` / `#DFF3E9` | `#58B98F` / `#143528` |
| `INFO` / `INFO_SOFT` | 提示 | `#315B96` / `#E7EFFB` | `#7FA8DC` / `#1B2C42` |
| `DISABLED` | 禁用文字/描边 | `#AAB8B6` | `#5C6E6C` |
| `NAV_BACKGROUND` / `NAV_TEXT` | 管理端侧栏底与其上文字 | `#193331` / `#FFFFFF` | `#0C1514` / `#E6F1EF` |

**说明**：`NAV_*` 是为深色模式补的语义槽。此前侧栏复用 `TEXT` 当背景、`SURFACE` 当文字，深色下会整体反色，属典型"借槽位"反例，后续禁止再借。

---

## 3. 字号字阶（`AppText`，单位 fp）

| Token | 值 | 用法 |
|---|---|---|
| `DISPLAY` | 30 | 登录页大标题、看板大数字 |
| `GLYPH` | 28 | 空状态图标字符 |
| `TITLE` | 24 | 页头标题、大标题 |
| `LEAD` | 20 | 快捷入口图标、次级强调 |
| `HEADING` | 18 | 区块标题（`SectionTitle`） |
| `SUBHEADING` | 16 | 卡片小标题 |
| `BODY` | 16 | 正文、按钮文字（可读性下限） |
| `CAPTION` | 13 | 说明、标签、字段标签 |
| `MICRO` | 12 | 底部导航文字、图表轴标签（**下限，不得再小**） |

---

## 4. 尺寸与间距（`AppSize`，单位 vp）

| Token | 值 | 用法 |
|---|---|---|
| `BASE_GRID` | 4 | 最小网格（微调、圆角内缩） |
| `STEP_GRID` | 8 | 主网格步进 |
| `TOUCH_MIN` | 40 | **可点击元素最小边长**（热区红线） |
| `ICON_SM` / `ICON_MD` | 20 / 24 | 导航图标、行内图标 |
| `PAGE_PADDING` | 16 | 页面左右留白 |
| `CARD_RADIUS` | 8 | 卡片圆角 |
| `CONTROL_RADIUS` | 8 | 输入控件、胶囊、按钮圆角 |
| `GAP` | 12 | 同级元素间距 |
| `SECTION_GAP` | 20 | 区块之间间距 |
| `CONTROL_HEIGHT` | 44 | 输入框、主按钮高度 |

固定布局值：页头高 `56`、底部导航高 `64`、导航项高 `56`、分段控件内缩 `3`。

---

## 5. 深色模式机制

- **状态**：`ThemeMode.AUTO | LIGHT | DARK`，存于 `KeyValueStore` 的 `theme_mode`，重启保持。
- **系统跟随**：`AUTO` 下通过 `mediaquery.matchMediaSync('(prefers-color-scheme: dark)')` 监听，系统切换时自动刷新（`ThemeManager.initialize()` 注册）。
- **刷新机制**：`AppColor` 是**静态 getter，非响应式**。`ThemeManager.setOnChange()` 触发后，`entry/src/main/ets/pages/Index.ets` 递增 `themeTick`，用奇偶双分支**销毁并重建整棵页面树**，使所有颜色重新取值。
  - 因此：**新增页面无需关心主题**，只要颜色走 `AppColor` 就会自动生效；但页面内若有"一次性计算并存字段"的颜色变量，会在重建前保持旧值，应避免这种写法。
- **用户入口**：患者端「我的 → 外观」提供 跟随系统 / 浅色 / 深色 三选一。

---

## 6. 公共组件清单（`common-core/src/main/ets/ui/CommonComponents.ets`）

| 组件 | 参数 | 关键规格 |
|---|---|---|
| `AppButton` | `text`, `isEnabled=true`, `secondary=false`, `onTap` | 高 `CONTROL_HEIGHT`；主态实底、次态浅底描边；禁用态 `SURFACE_ALT` |
| `PageHeader` | `title`, `subtitle`, `showBack=false` | 高 `56`；返回键 `40×40` 热区，走 `AppRouter.back()` |
| `SectionTitle` | `title`, `action=''`, `onAction` | 高 `40`；右侧文字操作补齐 `minHeight 40` |
| `InfoBanner` | `message`, `tone='info'`, `actionText=''`, `onAction` | `tone` 取值 `info/success/warning/error`，自动配前景与浅底；操作按钮高 `40` |
| `EmptyState` | `title='暂无数据'`, `description` | 图标 `GLYPH` + 标题 + 说明 |
| `LoadingBlock` | `text='正在加载'` | 24 转圈 + 文案，上下留白 36 |
| `StatusChip` | `text`, `color=PRIMARY`, `chipBackground=PRIMARY_SOFT` | 胶囊，左右内缩 10 |
| `FieldLabel` | `label`, `required=false` | 必填时红色 `*` |
| `BottomNav` | `currentRoute` | 固定 5 项（首页/分诊/挂号/就诊/我的），高 `64`，选中 `PRIMARY_DARK` |
| `RoutePage` | `content`（`@BuilderParam`） | 全屏容器骨架 |

患者端「我的 → 外观」的三选一分段控件使用 `SURFACE_ALT` 底 + `PRIMARY_SOFT` 选中块，可作为后续所有分段控件的范式。

---

## 7. 状态管理约定（ArkUI V2）

- 页面统一 **`@ComponentV2`**，组件内局部状态用 **`@Local`**，对外入参用 **`@Param`**，回调用 **`@Event`**。
- 禁止跨页面共享可变单例状态；跨页数据通过 `AppRouter.getParams()` 传递或进 `SessionStore`。
- 异步加载统一模式：`loading` 布尔 + `errorMessage` 字符串 + `InfoBanner` 呈现错误；接口异常一律 `ApiError.from(error).userMessage()`，禁止把原始堆栈显示给用户。

---

## 8. 路由与登录拦截

- 路由常量集中在 `RouteName`（患者 10 / 医生 3 / 管理 7），跳转统一 `AppRouter.replace|push|back|reset`。
- **统一守卫**：`AuthGuard.reroute()` 在 `AppRouter.replace()` 内生效（由 `AppBootstrap` 注册）：
  - 三个登录页免检；
  - `doctor-*` 需 `token + role=doctor`，否则回落 `doctor-login`；
  - `admin-*` 需 `token + role=admin`，否则回落 `admin-login`；
  - 其余需 `token + role=patient`，否则回落 `login`。
- 因此**各端 Root 内不再重复写登录检查**（已从 `PatientRoot/DoctorRoot/AdminRoot` 移除）。
- 冷启动分流：`entry/pages/Index.ets` 依据 `SessionStore` 的 token 与 role 决定首路由；`EntryAbility` 无条件注册三个 feature（否则首装 `role` 为空会让医生/管理端入口不可达）。

---

## 9. 公共持久化层

| 类 | 职责 | 注意 |
|---|---|---|
| `SessionStore` | 登录态、角色、预问诊会话、API 配置 | 所有 setter 必须立即持久化（此前 `setPrevisitSessionId` / `setApiConfig` 漏持久化，已修复） |
| `KeyValueStore` | 通用偏好存储（Preferences） | setter 主动 `flush`，避免进程被杀丢值 |
| `FileStore` | JSON 文件读写（`fileIo`） | 文件名走白名单校验，禁止外部传入路径拼接 |

---

## 10. 核心页面骨架标注

患者端标准页（首页 / 分诊 / 挂号等）统一结构：

```
┌──────────────────────────────────────┐
│ PageHeader                    高 56  │  title 24 / subtitle 13
├──────────────────────────────────────┤
│ Scroll                               │  左右 padding 16
│  ┌────────────────────────────────┐  │
│  │ 卡片  SURFACE / radius 8       │  │  区块间距 20，元素间距 12
│  │  SectionTitle 高 40            │  │
│  │  内容…                          │  │  控件高 44，热区 ≥40
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│ BottomNav                     高 64  │  图标 20 / 文字 12
└──────────────────────────────────────┘
```

- **登录页**：大标题 `DISPLAY 30` + 服务模式说明；快捷填充/演示账号按钮统一 `TOUCH_MIN`；错误用 `InfoBanner(tone='error')`。
- **首页**：快捷入口为 5 宫格图标（`LEAD 20`，容器 `40×40`）+ 公告/就诊卡片。
- **分诊页**：长文本输入 + 提交主按钮；危险征象走 `DANGER` 与 `DANGER_SOFT`。
- **挂号页**：科室/日期/午别为分段筛选（高 `TOUCH_MIN`），号源列表为卡片行，余号数为强调数字。

医生端、管理端去掉 `BottomNav`；管理端改为左侧栏（`NAV_BACKGROUND` 底、`NAV_TEXT` 字，宽固定、选中项 `PRIMARY_SOFT` 底）。

---

## 11. 双端差异与对齐（鸿蒙 ArkTS ↔ Android Compose / MD3）

`android-patient` 当前仅 5 个 `.kt`、无主题层，以下为**待落地时应遵守的映射**：

| 语义 | 鸿蒙（vp / fp，`AppColor`/`AppText`） | Android（dp / sp，MaterialTheme） |
|---|---|---|
| 主色 | `AppColor.PRIMARY` = `#00A9A7` | `colorScheme.primary` = `#00A9A7` |
| 主色上文字 | `PRIMARY_DARK` | `onPrimary` |
| 页面底 / 卡片 | `BACKGROUND` / `SURFACE` | `background` / `surface` |
| 主文字 / 次要 | `TEXT` / `TEXT_SECONDARY` | `onSurface` / `onSurfaceVariant` |
| 错误 | `DANGER` / `DANGER_SOFT` | `error` / `errorContainer` |
| 正文 | `AppText.BODY` = 16fp | `bodyLarge` = 16sp |
| 标题 | `TITLE` = 24fp | `headlineSmall` ≈ 24sp |
| 说明 | `CAPTION` = 13fp | `bodySmall` ≈ 12–13sp |
| 热区 | `TOUCH_MIN` = 40vp | `48dp`（MD3 建议；两端各自取本平台下限） |
| 圆角 | 卡片 8 / 控件 8 | `shape.small` 8 / `shape.medium` 12 |

差异要点：
1. 鸿蒙用 `vp/fp`，Android 用 `dp/sp`；**数值可对齐，单位不可混写**。
2. 鸿蒙深浅模式需手动重建页面树（见 §5）；Android 由 `colorScheme` + `isSystemInDarkTheme()` 自动重组。
3. 鸿蒙端当前字符图标（⌂ ◎ ＋ □ 人）为占位方案，Android 端应使用矢量图标；两端最终需统一为图标资源。

---

## 12. 待办与需协助事项

- **需 B（业务页面）协助**：管理端缺患者档案、症状标签库、AI 工具中心/Agent/AI 观测页；新增页面须按 §6 使用公共组件、按 §10 骨架排版。
- **需 D（Android）协助**：按 §11 建立 `Theme/Color/Type`，并回传实际取值以修正映射表。
- **需 A（服务端/联调）协助**：提供真机联调环境后，验证深色模式下 SSE 流式页、图表页的对比度。
- **待 C 后续**：字符图标替换为矢量资源；为图表类页面补深色色序。
