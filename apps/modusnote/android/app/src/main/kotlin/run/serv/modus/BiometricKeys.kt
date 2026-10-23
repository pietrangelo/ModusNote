package run.serv.modus

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/**
 * The fingerprint (or face) as the vault's passkey: an HMAC-SHA256 key in
 * the Android Keystore that only a strong biometric, confirmed in a
 * BiometricPrompt for each use, lets compute. The HMAC of the vault's salt
 * plays the part of the WebAuthn PRF output. The key never leaves the
 * Keystore (StrongBox where the phone has one) and a fingerprint added to
 * the phone invalidates it, so someone who learns the screen PIN cannot
 * enroll a finger of their own and open the vault.
 *
 * Only from Android 11, where a key can require a strong biometric for
 * every single use; there is no device-credential fallback, which the PIN
 * alone would satisfy.
 */
class BiometricKeys(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "forget") {
            val alias = call.argument<String>("alias")
            if (alias != null && alias.startsWith(PREFIX)) {
                keyStore.deleteEntry(alias)
            }
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (call.method == "isSupported") result.success(false)
            else result.error("unavailable", null, null)
            return
        }
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "create" -> create(call.argument<String>("alias"), result)
            "evaluate" -> evaluate(call, result)
            else -> result.notImplemented()
        }
    }

    /** The phone has the hardware, enrolled or not. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun isSupported(): Boolean {
        val manager = activity.getSystemService(BiometricManager::class.java) ?: return false
        return when (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS,
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> true
            else -> false
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun create(alias: String?, result: MethodChannel.Result) {
        if (alias == null || !alias.startsWith(PREFIX)) {
            result.error("unavailable", null, null)
            return
        }
        val manager = activity.getSystemService(BiometricManager::class.java)
        if (manager?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) !=
            BiometricManager.BIOMETRIC_SUCCESS
        ) {
            result.error("unavailable", null, null)
            return
        }
        val strongBox = activity.packageManager.hasSystemFeature("android.hardware.strongbox_keystore")
        try {
            try {
                generate(alias, strongBox)
            } catch (e: StrongBoxUnavailableException) {
                generate(alias, strongBox = false)
            }
        } catch (e: Exception) {
            result.error("unavailable", null, null)
            return
        }
        result.success(null)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun generate(alias: String, strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setUserAuthenticationRequired(true)
            // Every use asks for the biometric: no time window, no PIN.
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, KEYSTORE)
        generator.init(spec)
        generator.generateKey()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun evaluate(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.argument<String>("alias")
        val salt = call.argument<ByteArray>("salt")
        val title = call.argument<String>("title") ?: ""
        val subtitle = call.argument<String>("subtitle") ?: ""
        val cancel = call.argument<String>("cancel") ?: ""
        if (alias == null || !alias.startsWith(PREFIX) || salt == null) {
            result.error("unavailable", null, null)
            return
        }
        val mac: Mac
        try {
            val key = keyStore.getKey(alias, null) as? SecretKey
            if (key == null) {
                result.error("missing", null, null)
                return
            }
            mac = Mac.getInstance(MAC)
            mac.init(key)
        } catch (e: KeyPermanentlyInvalidatedException) {
            // A fingerprint was added or all were removed: the key is gone
            // for good.
            keyStore.deleteEntry(alias)
            result.error("invalidated", null, null)
            return
        } catch (e: UnrecoverableKeyException) {
            result.error("invalidated", null, null)
            return
        } catch (e: Exception) {
            result.error("unavailable", null, null)
            return
        }

        val executor = activity.mainExecutor
        val cancellation = CancellationSignal()
        var answered = false
        fun answer(block: () -> Unit) {
            if (answered) return
            answered = true
            block()
        }
        val prompt = BiometricPrompt.Builder(activity)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .setNegativeButton(cancel, executor) { _, _ ->
                answer { result.error("cancelled", null, null) }
            }
            .build()
        prompt.authenticate(
            BiometricPrompt.CryptoObject(mac),
            cancellation,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(outcome: BiometricPrompt.AuthenticationResult) {
                    answer {
                        val unlocked = outcome.cryptoObject?.mac
                        if (unlocked == null) {
                            result.error("unavailable", null, null)
                        } else {
                            try {
                                result.success(unlocked.doFinal(salt))
                            } catch (e: Exception) {
                                result.error("unavailable", null, null)
                            }
                        }
                    }
                }

                override fun onAuthenticationError(code: Int, message: CharSequence?) {
                    answer {
                        when (code) {
                            BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                            BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                            BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE ->
                                result.error("unavailable", null, null)
                            // Cancelled, timed out, or too many attempts:
                            // the prompt has said which.
                            else -> result.error("cancelled", null, null)
                        }
                    }
                }

                // A finger that does not match leaves the prompt open.
            },
        )
    }

    companion object {
        const val CHANNEL = "run.serv.modus/biometric"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val MAC = "HmacSHA256"

        /** Only keys this class made can be used or deleted through it. */
        private const val PREFIX = "modus-vault-"
    }
}
