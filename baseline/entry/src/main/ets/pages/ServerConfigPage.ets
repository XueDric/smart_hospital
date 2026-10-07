// 负责人：彭翌菲
// App 启动后的第一道页面：确认服务端 IP，注入 HTTP 地址后再进入鉴权流程。

import { HttpClient } from '../api/HttpClient';
import {
  DEFAULT_SERVER_ADDRESS,
  buildBaseUrl,
  isValidServerAddress,
  normalizeServerAddress,
} from '../config/Env';
import { Color, FontSize, Radius, Shadow, Space } from '../core/Theme';
import { ServerConfigStore } from '../store/ServerConfigStore';
import { replaceTo } from '../utils/RouterUtils';

@Entry
@Component
struct ServerConfigPage {
  @State address: string = DEFAULT_SERVER_ADDRESS;
  @State addressError: string = '';
  @State addressFocused: boolean = false;
  @State connecting: boolean = false;

  private serverConfigStore: ServerConfigStore = ServerConfigStore.getInstance();

  aboutToAppear(): void {
    this.loadSavedAddress();
  }

  build() {
    Column() {
      Column({ space: 18 }) {
        Image($r('app.media.new_logo'))
          .width(64)
          .height(64)
          .objectFit(ImageFit.Contain)

        Column({ space: 6 }) {
          Text('连接服务端')
            .fontSize(24)
            .fontWeight(700)
            .fontColor(Color.textPrimary)

          Text('输入服务端所在设备的 IP 地址后继续')
            .fontSize(FontSize.body)
            .fontColor(Color.textTertiary)
            .textAlign(TextAlign.Center)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 72 })

      Column({ space: 12 }) {
        Column({ space: 6 }) {
          Text('服务端 IP 地址')
            .width('100%')
            .fontSize(FontSize.body)
            .fontColor(Color.textSecondary)

          TextInput({
            placeholder: '例如 192.168.1.100',
            text: this.address,
          })
            .type(InputType.Normal)
            .maxLength(64)
            .height(52)
            .fontSize(15)
            .fontColor(Color.textPrimary)
            .placeholderColor(Color.textTertiary)
            .backgroundColor('#F9FAFB')
            .borderRadius(Radius.input)
            .border({
              width: this.addressError.length > 0 || this.addressFocused ? 1 : 0,
              color: this.addressError.length > 0
                ? Color.danger
                : (this.addressFocused ? Color.primary : Color.border),
            })
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.address = value;
              this.addressError = '';
            })
            .onFocus(() => {
              this.addressFocused = true;
            })
            .onBlur(() => {
              this.addressFocused = false;
            })

          Text('默认端口 8080；端口不同可填写“IP:端口”')
            .width('100%')
            .fontSize(FontSize.caption)
            .fontColor(Color.textTertiary)

          if (this.addressError.length > 0) {
            Text(this.addressError)
              .width('100%')
              .fontSize(FontSize.caption)
              .fontColor(Color.danger)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Button(this.connecting ? '正在进入…' : '连接并进入')
          .width('100%')
          .height(52)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Color.onPrimary)
          .backgroundColor(Color.primary)
          .borderRadius(Radius.button)
          .shadow(Shadow.primary)
          .enabled(!this.connecting)
          .opacity(this.connecting ? 0.7 : 1)
          .onClick(() => this.connect())
      }
      .width('100%')
      .margin({ top: 56 })

      Text('服务端地址会在本机保留，下次启动可继续使用。')
        .width('100%')
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 48, bottom: 32 })
    .backgroundColor(Color.surface)
  }

  private async connect(): Promise<void> {
    if (!isValidServerAddress(this.address)) {
      this.addressError = '请输入正确的服务器地址，例如 192.168.1.100:8080 或 example.com:8080';
      return;
    }

    const baseUrl: string = buildBaseUrl(this.address);
    this.connecting = true;
    try {
      await this.serverConfigStore.setCustomBaseUrl(getContext(this), baseUrl);
      HttpClient.getInstance().setBaseUrl(baseUrl);
      replaceTo('pages/Index');
    } catch (err) {
      this.addressError = '地址保存失败，请重试';
      this.connecting = false;
    }
  }

  private async loadSavedAddress(): Promise<void> {
    const savedBaseUrl: string | null = await this.serverConfigStore.getCustomBaseUrl(getContext(this));
    if (savedBaseUrl === null || savedBaseUrl.length === 0) {
      return;
    }

    const savedAddress: string = normalizeServerAddress(savedBaseUrl);
    if (isValidServerAddress(savedAddress)) {
      this.address = savedAddress;
    }
  }
}
