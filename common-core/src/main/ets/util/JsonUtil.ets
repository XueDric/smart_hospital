export function asRecord(value: Object | undefined): Record<string, Object> {
  if (value === undefined || value === null || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, Object>;
}

export function asString(value: Object | undefined, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  return String(value);
}

export function asNumber(value: Object | undefined, fallback: number = 0): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isNaN(parsed) ? fallback : parsed;
}

export function asBool(value: Object | undefined, fallback: boolean = false): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  return Boolean(value);
}

export function asArray(value: Object | undefined): Object[] {
  return Array.isArray(value) ? value as Object[] : [];
}

export function asStringMap(value: Object | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  const source = asRecord(value);
  const keys = Object.keys(source);
  for (const key of keys) {
    result[key] = asString(source[key], '');
  }
  return result;
}
