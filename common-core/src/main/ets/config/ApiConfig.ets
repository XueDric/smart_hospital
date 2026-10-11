export enum ApiMode {
  LIVE = 'live',
  MOCK = 'mock'
}

export class ApiConfig {
  private static modeValue: ApiMode = ApiMode.LIVE;
  private static baseUrlValue: string = 'http://127.0.0.1:8091';

  static get mode(): ApiMode {
    return ApiConfig.modeValue;
  }

  static set mode(value: ApiMode) {
    ApiConfig.modeValue = value;
  }

  static get baseUrl(): string {
    return ApiConfig.baseUrlValue;
  }

  static set baseUrl(value: string) {
    ApiConfig.baseUrlValue = ApiConfig.normalizeBaseUrl(value);
  }

  static isMock(): boolean {
    return ApiConfig.modeValue === ApiMode.MOCK;
  }

  static restore(mode: string, baseUrl: string): void {
    ApiConfig.modeValue = mode === ApiMode.MOCK ? ApiMode.MOCK : ApiMode.LIVE;
    if (baseUrl.length > 0) {
      ApiConfig.baseUrlValue = ApiConfig.normalizeBaseUrl(baseUrl);
    }
  }

  static normalizeBaseUrl(value: string): string {
    let normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.length > 0 ? normalized : 'http://127.0.0.1:8091';
  }

  static url(path: string): string {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return `${ApiConfig.baseUrlValue}${path.startsWith('/') ? path : `/${path}`}`;
  }
}
