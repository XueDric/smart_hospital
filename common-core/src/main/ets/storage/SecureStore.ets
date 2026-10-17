import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ===== SecureStore.ets —— 会话令牌的**加密**落盘（评审 P2-14）=========
 *
 * ⚠ 改这一处的原因（评审原话：`SessionStore.ets:33-49` 与 `SessionStore.kt:17`
 *   "token 明文落盘"）：
 *   `@kit.ArkData` 的 `preferences` 是**明文** KV（底层是普通 XML/文件），
 *   存进去的 token 在**有 root 的机器**或**备份导出**里都是可读的。
 *   而本仓的 token 是 `Bearer` 全权凭证 —— 有效期 12 小时、可读该患者全部病历。
 *   ⇒ 令牌不该用"存普通配置的方式"存。
 *
 * ## 为什么用 Asset Store Kit（`@kit.AssetStoreKit`）而不是自己加密
 *
 * 三条逐一看：
 *   ① **自己拿一个硬编码 key 去 AES**：key 就在 apk 里，等于把锁和钥匙一起发出去，
 *      是"看起来加密"的典型反例 —— 不做。
 *   ② **用 HUKS 存 key + 自己 AES**：可行，但要自己管 IV、管轮换、管 key 丢失后
 *      的降级路径，代码量是这里的 5 倍，而且每个边界都要自己证一遍。
 *   ③ **系统安全存储（Asset Store Kit）**：系统级的"存小秘密"服务，
 *      密钥由**系统**托管（不在应用沙箱里），读出时可绑定"设备首次解锁"
 *      这类访问控制。这正是 token / 口令这类短期秘密的标准做法
 *      （官方文档：`security/AssetStoreKit`）。
 *   本仓选 ③：少写代码、少写错、key 不在自己手里。
 *
 * ## 失败时的行为（**刻意**不静默降级成明文）
 *
 * Asset 服务不可用（极老设备、服务异常）时**不**退回 preferences 明文 ——
 * 那等于把评审指出的缺陷换个 key 名继续存在。此时令牌只留在**内存**里：
 * 本次使用完全正常，重启后需要重新登录。宁可"少记住一次登录"，
 * 也不"把全权凭证明文落盘"。
 * 失败原因用 `hilog` 打出来（不含令牌本体），并可用 `lastError()` 查。
 */

const TAG: string = 'SecureStore';

/* 读令牌失败里的"没这条"是**正常**状态（首次登录前），不该当错误刷日志。 */
const ERR_NOT_FOUND: number = 24000002;

export class SecureStore {
  /* 最近一次失败原因（给排障用；不含秘密本体）。空串表示没有失败。 */
  private static lastErrorValue: string = '';

  static lastError(): string {
    return SecureStore.lastErrorValue;
  }

  static clearLastError(): void {
    SecureStore.lastErrorValue = '';
  }

  /*
   * 写入一个秘密（同别名**覆盖**：先删再加，因为 Asset 的 add 遇到已存在会报错）。
   * 返回 true = 真的落到了系统安全存储。
   */
  static async put(alias: string, secret: string): Promise<boolean> {
    if (secret.length === 0) {
      await SecureStore.remove(alias);
      return true;
    }
    /* 覆盖语义：先尝试删除旧值，删除失败（不存在）不算错。 */
    await SecureStore.remove(alias);
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.ALIAS, SecureStore.toBytes(alias));
    attr.set(asset.Tag.SECRET, SecureStore.toBytes(secret));
    /*
     * DEVICE_FIRST_UNLOCKED：开机首次解锁后可读 —— 令牌属于"本人拿着手机就该能用"，
     * 不该要求每次读都再过一次锁屏（DEVICE_UNLOCKED 会让后台刷新令牌失败）。
     */
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attr);
      SecureStore.clearLastError();
      return true;
    } catch (error) {
      const e = error as BusinessError;
      SecureStore.lastErrorValue = `asset.add 失败：${e.code} ${e.message}`;
      /* ⚠ 不打印 secret，只打印别名与错误码。 */
      console.error(`[${TAG}] 写入安全存储失败（别名 ${alias}）：${e.code}`);
      return false;
    }
  }

  /* 读取秘密；不存在时返回空串（**不是**抛异常 —— 首次登录前就该是空）。 */
  static async get(alias: string): Promise<string> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, SecureStore.toBytes(alias));
    /* 必须显式要 ALL，否则只回属性、不回 SECRET。 */
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const rows: Array<asset.AssetMap> = await asset.query(query);
      if (rows.length === 0) {
        return '';
      }
      const value: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
      if (value === undefined) {
        return '';
      }
      return SecureStore.fromBytes(value as Uint8Array);
    } catch (error) {
      const e = error as BusinessError;
      if (e.code === ERR_NOT_FOUND) {
        return '';
      }
      SecureStore.lastErrorValue = `asset.query 失败：${e.code} ${e.message}`;
      console.error(`[${TAG}] 读取安全存储失败（别名 ${alias}）：${e.code}`);
      return '';
    }
  }

  /* 删除秘密；不存在不算错（登出时重复调用必须安全）。 */
  static async remove(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, SecureStore.toBytes(alias));
    try {
      await asset.remove(query);
    } catch (error) {
      const e = error as BusinessError;
      if (e.code === ERR_NOT_FOUND) {
        return;
      }
      SecureStore.lastErrorValue = `asset.remove 失败：${e.code} ${e.message}`;
      console.error(`[${TAG}] 删除安全存储失败（别名 ${alias}）：${e.code}`);
    }
  }

  private static toBytes(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private static fromBytes(value: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(value);
  }
}
