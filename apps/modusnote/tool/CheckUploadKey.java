import java.io.FileInputStream;
import java.io.InputStream;
import java.security.KeyStore;
import java.security.UnrecoverableKeyException;

/**
 * Opens the upload key the way Gradle will, before a build that takes a
 * quarter of an hour fails at its last step. Run as a single-file program:
 *
 *   java tool/CheckUploadKey.java <keystore>
 *
 * The passwords and the alias come from the environment (STORE_PASSWORD,
 * KEY_PASSWORD, KEY_ALIAS), never from the command line, and are never
 * printed. Prints `key` when KEY_PASSWORD opens the key, `store` when only
 * STORE_PASSWORD does (keytool ignores a separate key password for PKCS12
 * keystores, its default, so the key password is the store password), and
 * exits non-zero with the reason otherwise.
 */
public class CheckUploadKey {
  public static void main(String[] args) throws Exception {
    String storePassword = System.getenv("STORE_PASSWORD");
    String keyPassword = System.getenv("KEY_PASSWORD");
    String alias = System.getenv("KEY_ALIAS");

    KeyStore store = null;
    String failure = null;
    for (String type : new String[] {"PKCS12", "JKS"}) {
      try (InputStream in = new FileInputStream(args[0])) {
        KeyStore candidate = KeyStore.getInstance(type);
        candidate.load(in, storePassword.toCharArray());
        store = candidate;
        break;
      } catch (Exception e) {
        if (failure == null) failure = e.getMessage();
      }
    }
    if (store == null) {
      fail("the keystore does not open with ANDROID_UPLOAD_STORE_PASSWORD"
          + " or is not a keystore (" + failure + ")");
    }
    if (!store.isKeyEntry(alias)) {
      fail("the keystore has no key named ANDROID_UPLOAD_KEY_ALIAS"
          + " (its aliases: " + String.join(", ", java.util.Collections.list(store.aliases())) + ")");
    }
    if (opens(store, alias, keyPassword)) {
      System.out.println("key");
    } else if (opens(store, alias, storePassword)) {
      System.out.println("store");
    } else {
      fail("neither ANDROID_UPLOAD_KEY_PASSWORD nor ANDROID_UPLOAD_STORE_PASSWORD"
          + " opens the key");
    }
  }

  private static boolean opens(KeyStore store, String alias, String password)
      throws Exception {
    try {
      return store.getKey(alias, password.toCharArray()) != null;
    } catch (UnrecoverableKeyException e) {
      return false;
    }
  }

  private static void fail(String reason) {
    System.err.println("::error::Upload key: " + reason + ".");
    System.exit(1);
  }
}
