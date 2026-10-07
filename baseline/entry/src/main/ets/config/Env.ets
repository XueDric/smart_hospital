import BuildProfile from 'BuildProfile';

/**
 * 默认地址只用于启动页预填和临时固定配置。
 * 当前启动流程会先让用户确认服务端地址，再初始化网络请求。
 */
const DEV_SERVER_ADDRESS: string = '10.194.183.241';

/**
 * 发布包默认使用校园网地址。
 * 服务端固定后可直接以 BASE_URL 跳过启动页。
 */
const RELEASE_SERVER_ADDRESS: string = '10.179.153.237';

export const DEFAULT_SERVER_PORT: number = 8080;
export const DEFAULT_SERVER_ADDRESS: string =
  BuildProfile.DEBUG ? DEV_SERVER_ADDRESS : RELEASE_SERVER_ADDRESS;
export const BASE_URL: string = `http://${DEFAULT_SERVER_ADDRESS}:${DEFAULT_SERVER_PORT}/api/v1`;

export function normalizeServerAddress(value: string): string {
  let address: string = value.trim();
  const lower: string = address.toLowerCase();
  if (lower.startsWith('http://')) {
    address = address.substring(7);
  } else if (lower.startsWith('https://')) {
    address = address.substring(8);
  }

  const slashIndex: number = address.indexOf('/');
  if (slashIndex >= 0) {
    address = address.substring(0, slashIndex);
  }

  if (address.length > 0 && address.indexOf(':') < 0) {
    address = `${address}:${DEFAULT_SERVER_PORT}`;
  }
  return address;
}

function isIpv4(host: string): boolean {
  const octets: string[] = host.split('.');
  if (octets.length !== 4) {
    return false;
  }
  for (let i: number = 0; i < octets.length; i++) {
    if (!/^\d+$/.test(octets[i])) {
      return false;
    }
    const octet: number = parseInt(octets[i], 10);
    if (octet < 0 || octet > 255) {
      return false;
    }
  }
  return true;
}

// P0-2b：放开域名 —— 除了 IPv4，也接受合法主机名（公网部署后填域名可过校验）
function isHostname(host: string): boolean {
  if (host.length === 0) {
    return false;
  }
  const labels: string[] = host.split('.');
  for (let i: number = 0; i < labels.length; i++) {
    const label: string = labels[i];
    if (label.length === 0 || label.length > 63) {
      return false;
    }
    if (!/^[a-zA-Z0-9-]+$/.test(label)) {
      return false;
    }
    if (label.charAt(0) === '-' || label.charAt(label.length - 1) === '-') {
      return false;
    }
  }
  return true;
}

export function isValidServerAddress(value: string): boolean {
  const address: string = normalizeServerAddress(value);
  const separator: number = address.indexOf(':');
  if (separator <= 0 || address.indexOf(':', separator + 1) >= 0) {
    return false;
  }

  const host: string = address.substring(0, separator);
  const portText: string = address.substring(separator + 1);
  if (!/^\d+$/.test(portText)) {
    return false;
  }
  const port: number = parseInt(portText, 10);
  if (port < 1 || port > 65535) {
    return false;
  }

  return isIpv4(host) || isHostname(host);
}

export function buildBaseUrl(value: string): string {
  // P0-2b：保留 https 方案（公网/域名走 https 时不强行降级成 http）
  const lower: string = value.trim().toLowerCase();
  const scheme: string = lower.startsWith('https://') ? 'https://' : 'http://';
  return `${scheme}${normalizeServerAddress(value)}/api/v1`;
}
