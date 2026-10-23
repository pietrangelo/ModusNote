import '../l10n/generated/app_localizations.dart';

/// What the way into the vault besides the passphrase is called where the
/// app runs: a passkey in the browser, the fingerprint (or face) on
/// Android. Both are the same `PasskeyPrf` port underneath.
enum SecondFactor {
  passkey,
  biometric;

  String unlockAction(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyUnlockAction,
    biometric => l10n.biometricUnlockAction,
  };

  String settings(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeySettings,
    biometric => l10n.biometricSettings,
  };

  String setupBody(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeySetupBody,
    biometric => l10n.biometricSetupBody,
  };

  String setupAction(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeySetupAction,
    biometric => l10n.biometricSetupAction,
  };

  String activeBody(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyActiveBody,
    biometric => l10n.biometricActiveBody,
  };

  String ready(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyReady,
    biometric => l10n.biometricReady,
  };

  String removed(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyRemoved,
    biometric => l10n.biometricRemoved,
  };

  String cancelled(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyCancelled,
    biometric => l10n.biometricCancelled,
  };

  String rejected(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyRejected,
    biometric => l10n.biometricRejected,
  };

  String unsupported(AppLocalizations l10n) => switch (this) {
    passkey => l10n.passkeyUnsupported,
    biometric => l10n.biometricUnsupported,
  };

  String confirmAction(AppLocalizations l10n) => switch (this) {
    passkey => l10n.confirmWithPasskey,
    biometric => l10n.confirmWithBiometric,
  };
}
