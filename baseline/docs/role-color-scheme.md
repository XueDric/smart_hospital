# 成员头像配色规范（角色色阶）

> 📁 **角色配色方案** ｜ 本文件：`role-color-scheme.md` ｜ [全部文档目录](README.md)

> **唯一同源**：`docs/role-avatar-colors.csv`（原《新配色说明.csv》，2026-09-22 移入 `docs/` 并纳入版本管理，内容一字未改）
> **代码投影**：`entry/src/main/ets/core/Theme.ets` → `ROLE_AVATAR` / `roleAvatarToken()` / `AvatarBorderWidth`
> **适用范围**：成员名录（P06）行内头像 · 成员详情（P07）身份卡头像；后续任何"按角色着色"的圆形/胶囊标记都从这里取色
> **变更方式**：**先改 CSV，再同步 Theme.ets**。CSV 是设计侧交付物，Theme.ets 只是它的代码副本 —— 反过来改会让两处漂移。
> **当前版本**：v2 青绿阶（2026-09-22）。v1 蓝色阶已被取代，取值留档见 §6。

---

## 1. 色阶表

CSV 用同一条青绿明度阶表达"级别"：级别越高颜色越深，一眼能看出层级。

| 级别 | 职位（role 枚举） | 主色 | 渐变（上→下） | 头像内文字色 | 描边色 |
| --- | --- | --- | --- | --- | --- |
| L1（最高） | 会长 `president` | `#063B52` | `#063B52` → `#0B6E8F` | `#FFFFFF` | `#2DD4BF` |
| L2 | 副会长 `vice_president` | `#0B84B4` | `#0B84B4` → `#14B8A6` | `#FFFFFF` | `#5EEAD4` |
| L3 | 部长 `lead` | `#14B8A6` | `#14B8A6` → `#5EEAD4` | `#063B52` | `#99F6E4` |
| L4 | 副部长 `vice_lead` | `#34D399` | `#34D399` → `#A7F3D0` | `#063B52` | `#D9FBF0` |
| L5 | 成员 `member` | `#D7FBF0` | `#D7FBF0` → `#F5FEFC` | `#0B6E8F` | `#FFFFFF` |
| — | 未分配（`role = null`） | `#94A3B8` | `#94A3B8` → `#CBD5E1` | `#FFFFFF` | `#94A3B8` |
| — | 未知 role（兜底） | 同"未分配" | 同"未分配" | 同"未分配" | 同"未分配" |

> 最后两行**不在 CSV 内**。CSV 只定义了 5 档可指派角色；
> `pending` 账号的 `role` 为 `null`，无法落进任何一级，因此用**中性灰**兜底 —— 特意不用青绿阶，
> 读作"还没有级别"，与"L5 最浅"区分开。

`级别` 列在 CSV 里写作 `L1`–`L5`；代码里 `RoleAvatarToken.level` 存的是其序号 `1`–`5`（便于排序比较），兜底档为 `0`。

---

## 2. 头像的规范画法

| 部分 | 规则 | 取值来源 |
| --- | --- | --- |
| 形状 | 正圆：`borderRadius = 直径 / 2` | — |
| 填充 | 线性渐变，`angle: 180`（**上深 → 下浅**） | CSV「渐变（上→下）」两端的色值 |
| 文字 | 姓名首字，居中 | CSV「头像内文字色」逐级给定 |
| 描边 | `1px` 实色 | CSV「描边色」（每档都比该档渐变两端更亮，是设计给的高光圈） |
| 悬停描边 | 同一描边色，线宽加粗到 `2px` | **派生**：见下方说明 |
| 投影 | 角色色投影（主色 33% 透明） | **派生**：`shadow = main + '55'` |

**尺寸**：名录行 `40vp`（字号 14）、详情身份卡 `64vp`（字号 28），两者字号/直径比 ≈ 0.44 保持一致。

### 派生规则为什么这样定

CSV 只没给"投影 / 悬停"两条。为了**不引入新色相**（否则色板会失控），一律从已有色值派生：

- **描边色直接取 CSV，不再派生**：v2 的 CSV 新增了「描边色」列，且每档的描边色都比该档渐变的**两端都亮**（例：L1 `#2DD4BF` 亮于渐变终点 `#0B6E8F`）。既然设计已经给了高光圈，代码就不该再自己推一遍。
- **悬停改用"加粗"而不是"换色"**：正因描边色已是每档最亮的颜色，**比它更亮就得造新色相**。因此悬停保持同色、把线宽由 `1px` 加到 `2px`（`AvatarBorderWidth`）。描边绘制在组件外框以内，1 → 2 **不改变头像尺寸、不触发重排**。
- **投影取主色 + 33% 透明**：主色是每档的深端（L5 例外，见下），作投影色深浅两档都成立。
- **行级悬停底色不按角色派生**：刻意沿用既有的中性规范 `Color.canvas`（与 `ProfilePage` 一致）。若按角色派生，L5 主色 `#D7FBF0` 的 6% 淡化在白底上几乎不可见，会造成"低级别行悬停没反馈"的不一致体验。

### L5 的已知视觉特性（CSV 设计使然，非缺陷）

L5 的三条色值都接近白色：填充 `#D7FBF0 → #F5FEFC`、描边 `#FFFFFF`。因此在白底卡片上：

- 描边**看不见** —— 圆形的边界由极浅的填充色自己界定，这是"最低级别最轻"的层级表达；
- 悬停时描边加粗为 2px 白色仍不可见，投影 `#D7FBF055` 也极淡 → **L5 的悬停反馈主要落在行底色**（`Color.canvas`）上。

如果希望 L5 也有可见的描边或悬停反馈，需要设计侧在 CSV 里给 L5 换一个非白色的描边色。

---

## 3. 代码调用

### 3.1 取色接口（`core/Theme.ets`）

| 函数 / 常量 | 返回 | 用途 |
| --- | --- | --- |
| `roleAvatarToken(role)` | `RoleAvatarToken` | 拿整套 token（含 level / label / border / shadow） |
| `roleAvatarColor(role)` | 主色 | 渐变起点。**旧函数名保留**，既有调用无需改动 |
| `roleAvatarGradient(role)` | 渐变终点色 | 渐变终点 |
| `roleAvatarFg(role)` | 头像内文字色 | `fontColor` |
| `roleAvatarBorder(role)` | 描边色 | `border().color` |
| `roleAvatarShadow(role)` | 角色色投影色 | `shadow().color` |
| `AvatarBorderWidth` | `{ normal: 1, hover: 2 }` | 描边线宽（默认态 / 悬停态） |

`ROLE_AVATAR` 是可遍历的表（`Record<string, RoleAvatarToken>`），需要批量出图/校对色板时直接遍历它。
**取单个角色的颜色请用 `roleAvatarToken()`**，不要直接索引 —— 未知 role 会落到兜底档而不会拿到 `undefined`。

`roleAvatarFromCsv()` 的参数顺序与 CSV 列序一致（`主色 / 渐变终点 / 头像内文字色 / 描边色`），
从 CSV 抄新值进来时照着列序填即可。

### 3.2 名录行（`components/MemberCard.ets`）

```ts
Text(this.initial())
  .fontSize(FontSize.subtitle)
  .fontWeight(FontWeight.Medium)
  .fontColor(roleAvatarFg(this.member.role))
  .width(AVATAR_SIZE)
  .height(AVATAR_SIZE)
  .borderRadius(AVATAR_SIZE / 2)
  .linearGradient({
    angle: 180,
    colors: [[roleAvatarColor(this.member.role), 0.0], [roleAvatarGradient(this.member.role), 1.0]]
  })
  .border({
    width: this.isHover ? AvatarBorderWidth.hover : AvatarBorderWidth.normal,
    color: roleAvatarBorder(this.member.role)
  })
  // 悬停时浮起：角色色投影（非悬停态 radius/offset 归零，等同不投影）
  .shadow({
    radius: this.isHover ? 10 : 0,
    color: roleAvatarShadow(this.member.role),
    offsetX: 0,
    offsetY: this.isHover ? 3 : 0
  })
  .textAlign(TextAlign.Center)
```

悬停状态用 `@State isHover` + `onHover` 驱动（与 `ProfilePage` 的 `hoveredEntry` 同一套写法）：

```ts
  @State isHover: boolean = false
  ...
  .backgroundColor(this.isHover ? Color.canvas : '#00000000')
  .onHover((isHover: boolean) => {
    this.isHover = isHover
  })
```

### 3.3 详情身份卡（`pages/MemberDetailPage.ets`）

同一套取色，仅尺寸放大到 `AVATAR_SIZE = 64`、描边取 `AvatarBorderWidth.normal`。
详情页头像**不可交互**，因此把名录的"悬停态"提升为这里的"默认态"：常态就带角色色投影，让英雄区更立体。

---

## 4. 本次改动清单

| 文件 | 改动 |
| --- | --- |
| `docs/role-avatar-colors.csv` | **v2 内容**（由根目录《新配色说明.csv》移入；v1 蓝色阶已被取代，见 §6） |
| `docs/role-color-scheme.md` | **新增**（本文） |
| `core/Theme.ets` | 新增 `RoleAvatarToken` / `ROLE_AVATAR` / `ROLE_AVATAR_UNASSIGNED` / `AvatarBorderWidth` / `roleAvatarToken()` / `roleAvatarGradient()` / `roleAvatarFg()` / `roleAvatarBorder()` / `roleAvatarShadow()`；`roleAvatarColor()` 改为返回新色阶主色 |
| `components/MemberCard.ets` | 头像由"12% 淡底 + 角色色字"改为"上→下渐变填充 + 按级文字色 + CSV 描边色"；新增头像悬停态（描边加粗 + 角色色投影）与行悬停底色；删除只服务于旧画法的 `tint()` 助手 |
| `pages/MemberDetailPage.ets` | 头像同上改造（64vp）；常态带角色色投影；删除 `tint()` 助手 |

**迁移影响**：`roleAvatarColor()` 的返回值先是彩虹色（indigo / violet / green / amber / blue），v2 起为青绿阶主色。全仓只有名录与详情两处调用，均已同步改造。旧的 12% 淡底画法（`tint()`）只服务于头像，已随改动删除。

**编译验证**：
```bash
export DEVECO_SDK_HOME="E:\\Program Files\\DevEco Studio\\sdk"
export PATH="/e/Program Files/DevEco Studio/jbr/bin:/e/Program Files/DevEco Studio/tools/node:$PATH"
"/e/Program Files/DevEco Studio/tools/node/node.exe" \
  "E:/Program Files/DevEco Studio/tools/hvigor/bin/hvigorw.js" --no-daemon assembleHap
# → hvigor BUILD SUCCESSFUL（仅 ManagePage 的 AlertDialog 既有弃用告警）
```

**肉眼验证**：模拟器登录后看「名录」Tab —— L1/L2（会长、副会长）为深底白字，L3/L4（部长、副部长）为中底深青字，L5（成员）为极浅底青字，由上到下整体变浅；点进成员详情，头像应与名录同一色、更大且带同色投影。

---

## 5. 已知未覆盖 / 待决策

**角色胶囊（名录右侧徽标、详情身份徽标）仍是原来的彩虹色**（`roleBadgeFg` / `roleBadgeBg`：indigo / purple / green / amber / blue），没有跟着换成青绿阶。

原因是 CSV 只定义了头像相关的列（主色 / 渐变 / 头像内文字色 / 描边色），没有给徽标列。若要让徽标也统一到同一色阶，只有两种不引入新色相的做法，需要设计侧定夺：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| A. 实底徽标 | 底色 = 主色、文字 = CSV 的头像内文字色 | 与头像同色系、任意级别都可读；但徽标从"浅色描边感"变成"实色块"，视觉重量上升 |
| B. 淡底徽标（推荐） | 底色 = 主色 12% 淡化、文字 = **需要设计侧新增一列"徽标文字色"** | 保持现在的轻盈观感；但必须补这一列（否则 L5 的 `#D7FBF0` 配淡底、L3/L4 的中浅底都读不出来），不能在代码里自己调 |
| C. 不动 | 保持现状 | 会出现"青绿头像 + 绿色徽标（部长）"这类跨色系搭配，与统一色阶的初衷相悖 |

**当前状态**：保持 C（不动），等设计侧确认后再改。改动量很小 —— 只涉及 `roleBadgeFg()` / `roleBadgeBg()` 两个函数。

---

## 6. 变更记录

| 版本 | 日期 | 来源文件 | 色系 | 说明 |
| --- | --- | --- | --- | --- |
| v1 | 2026-09-21 | 《配色说明.csv》 | 蓝色单色阶 | 5 列（级别 / 职位 / 主色 / 渐变辅助色 / 头像内文字色）；**未给渐变方向与描边色**，当时由代码派生（渐变取 135°、`border = 主色`、`hoverBorder = 渐变辅助色`）。取值：`#0F2E57→#1D4E89` / `#1D4E89→#3B7BC4` / `#3B7BC4→#6BA3DC` / `#7BB0E0→#A8CCEC` / `#C3DCF0→#E4F0F9`；文字色前三级 `#FFFFFF`、后两级 `#0F2E57`。 |
| **v2（现行）** | 2026-09-22 | 《新配色说明.csv》 | 青绿单色阶 | 6 列，**新增「渐变（上→下）」方向与「描边色」**，级别改用 `L1`–`L5`。详见 §1。代码随之：渐变 `angle` 135 → **180**；描边色改为**直接取 CSV**；删掉已无依据的 `hoverBorder` 派生，悬停改为描边加粗。 |

> v1 的 CSV 文件本身已被 v2 覆盖，其取值以本表留档；如需完整还原可查本仓库 2026-09-21 的提交或对话记录。
