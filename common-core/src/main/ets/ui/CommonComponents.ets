import { AppRouter, RouteName } from '../router/AppRouter';
import { AppColor, AppSize, AppText } from './Theme';

@ComponentV2
export struct AppButton {
  @Param text: string = '';
  @Param isEnabled: boolean = true;
  @Param secondary: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Button(this.text)
      .width('100%')
      .height(AppSize.CONTROL_HEIGHT)
      .fontSize(AppText.BODY)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.secondary ? AppColor.PRIMARY : AppColor.SURFACE)
      .backgroundColor(this.isEnabled ? (this.secondary ? AppColor.PRIMARY_SOFT : AppColor.PRIMARY) :
        AppColor.SURFACE_ALT)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .border(this.secondary ? { width: 1, color: AppColor.PRIMARY } : { width: 0 })
      .enabled(this.isEnabled)
      .onClick(() => {
        if (this.isEnabled) {
          this.onTap();
        }
      })
  }
}

@ComponentV2
export struct PageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param showBack: boolean = false;

  build() {
    Row() {
      if (this.showBack) {
        Button('‹')
          .width(AppSize.TOUCH_MIN)
          .height(AppSize.TOUCH_MIN)
          .fontSize(AppText.TITLE)
          .fontColor(AppColor.TEXT)
          .backgroundColor(Color.Transparent)
          .onClick(() => AppRouter.getInstance().back())
      }
      Column() {
        Text(this.title)
          .fontSize(AppText.TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(56)
    .padding({ left: this.showBack ? 4 : AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
    .alignItems(VerticalAlign.Center)
  }
}

@ComponentV2
export struct SectionTitle {
  @Param title: string = '';
  @Param action: string = '';
  @Event onAction: () => void = () => {
  };

  build() {
    Row() {
      Text(this.title)
        .fontSize(AppText.HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
        .layoutWeight(1)
      if (this.action.length > 0) {
        Text(this.action)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.PRIMARY_DARK)
          .constraintSize({ minHeight: AppSize.TOUCH_MIN })
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }
}

@ComponentV2
export struct InfoBanner {
  @Param message: string = '';
  @Param tone: string = 'info';
  @Param actionText: string = '';
  @Event onAction: () => void = () => {
  };

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.message)
            .fontSize(AppText.BODY)
            .fontColor(this.foreground())
            .width('100%')
        }
        .layoutWeight(1)
        if (this.actionText.length > 0) {
          Button(this.actionText)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.foreground())
            .backgroundColor(Color.Transparent)
            .onClick(() => this.onAction())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.toneBackground())
    .borderRadius(AppSize.CARD_RADIUS)
  }

  private foreground(): string {
    if (this.tone === 'error') {
      return AppColor.DANGER;
    }
    if (this.tone === 'warning') {
      return AppColor.WARNING;
    }
    if (this.tone === 'success') {
      return AppColor.SUCCESS;
    }
    return AppColor.INFO;
  }

  private toneBackground(): string {
    if (this.tone === 'error') {
      return AppColor.DANGER_SOFT;
    }
    if (this.tone === 'warning') {
      return AppColor.WARNING_SOFT;
    }
    if (this.tone === 'success') {
      return AppColor.SUCCESS_SOFT;
    }
    return AppColor.INFO_SOFT;
  }
}

@ComponentV2
export struct EmptyState {
  @Param title: string = '暂无数据';
  @Param description: string = '';

  build() {
    Column() {
      Text('—')
        .fontSize(AppText.GLYPH)
        .fontColor(AppColor.PRIMARY)
      Text(this.title)
        .fontSize(AppText.SUBHEADING)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.TEXT)
        .margin({ top: 8 })
      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ top: 40, bottom: 40, left: 24, right: 24 })
    .alignItems(HorizontalAlign.Center)
  }
}

@ComponentV2
export struct LoadingBlock {
  @Param text: string = '正在加载';

  build() {
    Row() {
      LoadingProgress()
        .width(24)
        .height(24)
        .color(AppColor.PRIMARY)
      Text(this.text)
        .fontSize(AppText.BODY)
        .fontColor(AppColor.TEXT_SECONDARY)
        .margin({ left: 10 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 36, bottom: 36 })
  }
}

@ComponentV2
export struct StatusChip {
  @Param text: string = '';
  @Param color: string = AppColor.PRIMARY;
  @Param chipBackground: string = AppColor.PRIMARY_SOFT;

  build() {
    Text(this.text)
      .fontSize(AppText.CAPTION)
      .fontColor(this.color)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.chipBackground)
      .borderRadius(AppSize.CONTROL_RADIUS)
  }
}

@ComponentV2
export struct FieldLabel {
  @Param label: string = '';
  @Param required: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(AppText.CAPTION)
        .fontColor(AppColor.TEXT_SECONDARY)
      if (this.required) {
        Text(' *')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.DANGER)
      }
    }
    .width('100%')
    .margin({ bottom: 6 })
  }
}

export class NavItem {
  route: string = '';
  label: string = '';
  glyph: string = '';

  constructor(route: string, label: string, glyph: string) {
    this.route = route;
    this.label = label;
    this.glyph = glyph;
  }
}

@ComponentV2
export struct BottomNav {
  @Param currentRoute: string = RouteName.HOME;

  private readonly items: NavItem[] = [
    new NavItem(RouteName.HOME, '首页', '⌂'),
    new NavItem(RouteName.TRIAGE, '分诊', '◎'),
    new NavItem(RouteName.BOOKING, '挂号', '＋'),
    new NavItem(RouteName.APPOINTMENTS, '就诊', '□'),
    new NavItem(RouteName.PROFILE, '我的', '人')
  ];

  build() {
    Row() {
      ForEach(this.items, (item: NavItem) => {
        Column() {
          Text(item.glyph)
            .fontSize(AppSize.ICON_SM)
            .fontColor(this.isActive(item.route) ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .height(AppSize.ICON_SM)
          Text(item.label)
            .fontSize(AppText.MICRO)
            .fontColor(this.isActive(item.route) ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (item.route !== this.currentRoute) {
            AppRouter.getInstance().reset(item.route);
          }
        })
      }, (item: NavItem) => item.route)
    }
    .width('100%')
    .height(64)
    .padding({ left: 4, right: 4, bottom: 4 })
    .backgroundColor(AppColor.SURFACE)
    .border({ width: { top: 1 }, color: AppColor.BORDER })
  }

  private isActive(route: string): boolean {
    return this.currentRoute === route;
  }
}

@ComponentV2
export struct RoutePage {
  @BuilderParam content: () => void = this.empty;

  @Builder
  empty() {
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
  }
}
