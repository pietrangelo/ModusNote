# modusnote (app Flutter)

Shell dell'applicazione mobile. Contiene solo UI e wiring degli adapter: la logica di dominio vive nei pacchetti sotto `packages/`.

Le stringhe stanno in `lib/l10n/app_<lingua>.arb` (template: `app_en.arb`). Per aggiungere una lingua basta creare un nuovo file ARB; `flutter pub get` o `flutter run` rigenerano `AppLocalizations`.
