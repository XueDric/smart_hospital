package com.smart.hospital.patient.data

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 敏感小字段的落盘加密（评审 P2-14：「token 明文落盘」）。
 *
 * ## 问题
 * 改之前 `SessionStore` 用 `prefs.edit().putString("token", ...)` 把 64 位会话令牌
 * **明文**写进 SharedPreferences。任何拿到 `data/data/<包名>/shared_prefs/*.xml`
 * 的人（root、风控告警后 dump 的取证包、备份与 debug 导出的 APK 目录）都能直接
 * 拿这串东西冒充患者调接口，直到令牌过期为止。
 *
 * ## 方案
 * 密钥生成在 **AndroidKeyStore**（硬件/系统级保护，私钥不可导出），算法 AES-256-GCM；
 * 落盘的是 `v1:` + Base64(IV ‖ 密文 ‖ GCM tag)。选它而不是引入
 * `androidx.security:security-crypto` 的原因：本模块刻意**零第三方运行时依赖**，
 * 而这里只需要"加密一个字符串"，系统 API 就够，不值得为它引一个库。
 *
 * ## 三条硬约束（评审最容易被"半吊子加密"糊弄过去的地方）
 * 1. **绝不降级为明文**：Keystore 不可用（模拟器异常、厂商裁剪、系统升级后密钥失效）
 *    时返回 false，调用方把令牌**只留在内存**，重启要重新登录 —— 宁可掉登录，不留明文。
 * 2. **旧的明文必须先清掉**：升级上来的老设备 `prefs` 里可能还躺着 `token`
 *    （不带 `v1:` 前缀）。`get` 一旦识别到这种值，先删再当"没有"，而不是照旧使用。
 * 3. **GCM 的 IV 必须每次随机**：交给 `Cipher.init(ENCRYPT_MODE, key)` 自己生成，
 *    并随密文一起存；硬编码 IV 会让同一令牌两次加密得到同一个密文（等于泄露明文）。
 *
 * 说明：本类只处理"小字符串"。令牌本来就短，SharedPreferences + Base64 够用；
 * 不要拿它存大对象（那属于文件加密的范畴）。
 */
internal object SecretStore {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "smart_hospital.secret.v1"
    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val KEY_BITS = 256
    private const val PREFIX = "v1:"

    /** 最近一次失败原因（不含秘密本体），供设置页/日志排查用。 */
    @Volatile
    private var lastError: String? = null

    fun lastErrorText(): String? = lastError

    private fun secretKey(): SecretKey? = runCatching {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val existing = (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
        if (existing != null) {
            existing
        } else {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(KEY_BITS)
                    // 强制随机 IV：系统会拒绝用 fixed IV 的 GCM 加密，这是我们要的行为。
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generator.generateKey()
        }
    }.onFailure {
        lastError = "keystore unavailable: ${it.javaClass.simpleName}"
    }.getOrNull()

    /** 写入加密后的值；返回 false 表示没有落盘成功（调用方应只在内存保留）。 */
    fun put(prefs: SharedPreferences, key: String, value: String): Boolean {
        val secret = secretKey() ?: return false
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, secret) }
            val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            val blob = ByteArray(iv.size + cipherText.size)
            System.arraycopy(iv, 0, blob, 0, iv.size)
            System.arraycopy(cipherText, 0, blob, iv.size, cipherText.size)
            prefs.edit().putString(key, PREFIX + Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
        }.onFailure {
            lastError = "encrypt failed: ${it.javaClass.simpleName}"
        }.getOrDefault(false)
    }

    /**
     * 读取并解密；没有值、密钥失效、或发现"旧明文"时返回 null。
     * 旧明文会被删掉 —— 这是升级路径上的关键一步，否则加密只对新设备生效。
     */
    fun get(prefs: SharedPreferences, key: String): String? {
        val stored = prefs.getString(key, null) ?: return null
        if (!stored.startsWith(PREFIX)) {
            prefs.edit().remove(key).commit()
            lastError = "legacy plaintext value discarded"
            return null
        }
        val secret = secretKey() ?: return null
        return runCatching {
            val blob = Base64.decode(stored.removePrefix(PREFIX), Base64.NO_WRAP)
            if (blob.size <= IV_BYTES) return@runCatching null
            val iv = blob.copyOfRange(0, IV_BYTES)
            val cipherText = blob.copyOfRange(IV_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, iv))
            }
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        }.onFailure {
            // 解不开就当没有：删掉坏值，让用户重新登录，而不是一直拿空串重试。
            lastError = "decrypt failed: ${it.javaClass.simpleName}"
            prefs.edit().remove(key).commit()
        }.getOrNull()
    }

    fun remove(prefs: SharedPreferences, key: String) {
        prefs.edit().remove(key).commit()
    }

    /** 该键当前是否已是加密格式（自动化验收与排查用）。 */
    fun isEncrypted(prefs: SharedPreferences, key: String): Boolean =
        prefs.getString(key, null)?.startsWith(PREFIX) == true
}
