/**
 * 成员行 MemberCard
 * 郭俊杰负责
 * 左：角色色头像圈（姓名首字 · 主色→渐变终点 上→下渐变底 + CSV 描边色）· 中：姓名 + 「加入时间 · 部门」· 右：角色胶囊
 *
 * 设计约束（Figma / P06）：
 *   · 行本身**不带卡片外壳**（无阴影/圆角/边框）—— 由 MemberListPage 把整组包进
 *     一张 `divide-y` 的卡片里，行与行之间用 Divider 隔开，还原 Figma 的单卡分组；
 *   · 名录**不含手机号**（隐私最小化），行上只有姓名、加入时间、部门、角色徽标；
 *   · 颜色 / 圆角 / 间距一律取自 core/Theme.ets：
 *     头像走 roleAvatarToken() + AvatarBorderWidth（唯一同源 docs/role-avatar-colors.csv：
 *     主色 / 渐变（上→下）/ 头像内文字色 / 描边色），
 *     角色胶囊走 roleBadgeFg / roleBadgeBg，行悬停底色用中性的 Color.canvas。
 */
import { MemberBrief } from '../api/AuthApi'
import {
  AvatarBorderWidth, Color, FontSize, Radius, Space,
  memberStatusFg, memberStatusLabel,
  roleAvatarBorder, roleAvatarColor, roleAvatarFg, roleAvatarGradient, roleAvatarShadow,
  roleBadgeBg, roleBadgeFg, roleLabel
} from '../core/Theme'

/** 头像直径（vp）；圆角取一半即正圆。两处（名录 / 详情）比例保持一致。 */
const AVATAR_SIZE: number = 40

@Component
export struct MemberCard {
  @Prop member: MemberBrief
  onCardClick: () => void = () => {}
  @State isHover: boolean = false

  build() {
    Row({ space: Space.md }) {
      // ── 头像圈：docs/role-avatar-colors.csv 的 主色 → 渐变终点 上→下渐变底（angle 180）、
      //    CSV 描边色、按级取文字色。悬停只加粗描边（不换色、不动尺寸，避免触发重排）。
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

      // ── 姓名 + 加入时间 · 部门 ──
      Column({ space: 2 }) {
        Row() {
          Text(this.member.name)
            .fontSize(FontSize.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.member.status !== 'active') {
            Text(memberStatusLabel(this.member.status))
              .fontSize(FontSize.micro)
              .fontColor(memberStatusFg(this.member.status))
              .backgroundColor(Color.canvas)
              .borderRadius(Radius.pill)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: Space.sm })
          }
        }
        .width('100%')

        Text(this.subtitle())
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // ── 角色胶囊（Figma 右侧徽标）──
      Text(roleLabel(this.member.role))
        .fontSize(FontSize.micro)
        .fontWeight(FontWeight.Medium)
        .fontColor(roleBadgeFg(this.member.role))
        .backgroundColor(roleBadgeBg(this.member.role))
        .borderRadius(Radius.pill)
        .padding({ left: 10, right: 10, top: 3, bottom: 3 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
    .backgroundColor(this.isHover ? Color.canvas : '#00000000')
    .onHover((isHover: boolean) => {
      this.isHover = isHover
    })
    .onClick(() => {
      this.onCardClick()
    })
  }

  /** 姓名首字；姓名为空时用占位符，避免 substring 越界。 */
  private initial(): string {
    if (this.member.name.length === 0) {
      return '?'
    }
    return this.member.name.substring(0, 1)
  }

  /** 副信息：「YYYY-MM 加入 · 部门」（pending 账号 dept 为 null，落到「未分配部门」）。 */
  private subtitle(): string {
    const deptName: string = this.member.dept?.name ?? '未分配部门'
    const joined: string = this.joinedMonth()
    if (joined.length === 0) {
      return deptName
    }
    return `${joined} 加入 · ${deptName}`
  }

  /** ISO 8601 → 「YYYY-MM」；拿不到就返回空串（整段不显示）。 */
  private joinedMonth(): string {
    const raw: string | null = this.member.joined_at
    if (raw === null || raw === undefined || raw.length < 7) {
      return ''
    }
    return raw.substring(0, 7)
  }
}
