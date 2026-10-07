import { Color, FontSize, Radius, Space } from '../core/Theme';

@Component
export struct FormField {
  fieldLabel: string = '';
  placeholder: string = '';
  @Link inputValue: string;
  @Prop errorText: string = '';
  hint: string = '';
  isPassword: boolean = false;
  numeric: boolean = false;
  maxLength: number = 64;

  @State focused: boolean = false;
  @State showPassword: boolean = false;

  private fieldBorderColor(): string {
    if (this.errorText.length > 0) return Color.danger;
    if (this.focused) return Color.primary;
    return Color.inputBorder;
  }

  private inputType(): InputType {
    if (this.isPassword && !this.showPassword) return InputType.Password;
    if (this.numeric) return InputType.Number;
    return InputType.Normal;
  }

  build() {
    Column({ space: 6 }) {
      if (this.fieldLabel.length > 0) {
        Text(this.fieldLabel)
          .fontSize(FontSize.body)
          .fontColor(Color.textSecondary)
      }

      Row() {
        TextInput({ placeholder: this.placeholder, text: this.inputValue })
          .type(this.inputType())
          .showPasswordIcon(false)
          .maxLength(this.maxLength)
          .onChange((value: string) => {
            this.inputValue = value;
          })
          .onFocus(() => {
            this.focused = true;
          })
          .onBlur(() => {
            this.focused = false;
          })
          .layoutWeight(1)
          .height(48)
          .fontSize(FontSize.body)
          .fontFamily(this.numeric ? 'Inter' : 'Noto Sans SC')
          .fontFeature('"tnum" 1')
          .fontColor(Color.textPrimary)
          .placeholderColor(Color.textTertiary)
          .backgroundColor(Color.surface)
          .padding({ left: 14, right: this.isPassword ? 4 : 14 })

        if (this.isPassword) {
          Text(this.showPassword ? '隐藏' : '显示')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.primary)
            .padding({ left: 8, right: 14, top: 12, bottom: 12 })
            .onClick(() => {
              this.showPassword = !this.showPassword;
            })
        }
      }
      .width('100%')
      .height(48)
      .backgroundColor(Color.surface)
      .borderRadius(Radius.button)
      .border({ width: this.errorText.length > 0 ? 1.5 : 1, color: this.fieldBorderColor() })

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor(Color.danger)
      } else if (this.hint.length > 0) {
        Text(this.hint)
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Space.page, right: Space.page })
  }
}
