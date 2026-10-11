import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { ApiConfig } from '../config/ApiConfig';
import { ApiError, ErrorCode } from './ApiError';
import { HttpClient } from './HttpClient';

export interface SseHandlers {
  onMeta: (sessionId: string) => void;
  onDelta: (text: string) => void;
  onDone: () => void;
}

export class SseClient {
  private static instance: SseClient = new SseClient();
  private pending: Uint8Array = new Uint8Array(0);

  static getInstance(): SseClient {
    return SseClient.instance;
  }

  async open(path: string, handlers: SseHandlers): Promise<void> {
    const request = http.createHttp();
    let settled = false;
    let receivedDone = false;
    this.pending = new Uint8Array(0);

    return new Promise<void>((resolve, reject) => {
      const fail = (error: ApiError): void => {
        if (!settled) {
          settled = true;
          request.destroy();
          reject(error);
        }
      };
      const succeed = (): void => {
        if (!settled) {
          settled = true;
          request.destroy();
          resolve();
        }
      };

      request.on('dataReceive', (data: ArrayBuffer) => {
        try {
          this.appendChunk(new Uint8Array(data), (frame: string) => {
            const eventName = this.handleFrame(frame, handlers);
            if (eventName === 'done') {
              receivedDone = true;
            }
          });
        } catch (error) {
          fail(ApiError.from(error as Error));
        }
      });

      request.on('dataEnd', () => {
        if (!receivedDone) {
          fail(new ApiError(ErrorCode.SSE_INCOMPLETE, '预问诊流意外中断，请重试'));
          return;
        }
        handlers.onDone();
        succeed();
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Authorization': `Bearer ${this.readToken()}`
        },
        readTimeout: 120000,
        connectTimeout: 10000,
        usingCache: false
      };

      request.requestInStream(ApiConfig.url(path), options)
        .then((status: number) => {
          if (status < 200 || status >= 300) {
            fail(new ApiError(`HTTP_${status}`, `预问诊连接失败（HTTP ${status}）`, status));
          }
        })
        .catch((error: Error) => {
          fail(ApiError.from(error));
        });
    });
  }

  private appendChunk(chunk: Uint8Array, onFrame: (frame: string) => void): void {
    const combined = new Uint8Array(this.pending.length + chunk.length);
    combined.set(this.pending, 0);
    combined.set(chunk, this.pending.length);
    this.pending = combined;

    let consumed = 0;
    while (consumed < this.pending.length) {
      const delimiter = this.findDelimiter(this.pending, consumed);
      if (delimiter < 0) {
        break;
      }
      const frameBytes = this.pending.slice(consumed, delimiter);
      const frame = util.TextDecoder.create('utf-8').decodeToString(frameBytes);
      onFrame(frame);
      consumed = delimiter + 2;
    }
    if (consumed > 0) {
      this.pending = this.pending.slice(consumed);
    }
  }

  private findDelimiter(bytes: Uint8Array, start: number): number {
    for (let index = start; index < bytes.length - 1; index++) {
      if (bytes[index] === 10 && bytes[index + 1] === 10) {
        return index;
      }
    }
    return -1;
  }

  private handleFrame(frame: string, handlers: SseHandlers): string {
    let payload = frame;
    if (payload.startsWith('data:')) {
      payload = payload.substring(5).trim();
    }
    if (payload.length === 0) {
      return '';
    }
    const root = JSON.parse(payload) as Record<string, Object>;
    const eventName = String(root['event'] ?? '');
    const data = root['data'] as Record<string, Object>;
    if (eventName === 'meta') {
      handlers.onMeta(String(data['session_id'] ?? ''));
    } else if (eventName === 'delta') {
      handlers.onDelta(String(data['text'] ?? ''));
    } else if (eventName === 'done') {
      return 'done';
    } else if (eventName === 'error') {
      throw new ApiError(String(data['code'] ?? 'SSE_ERROR'), String(data['message'] ?? '预问诊失败'));
    }
    return eventName;
  }

  private readToken(): string {
    return HttpClient.getInstance().buildHeaders(true)['Authorization']?.replace('Bearer ', '') ?? '';
  }
}
