# ModusNote

Note offline-first, cifrate end-to-end, con un motore a schemi dinamici (canzoni, sogni, to-do, note libere) e registrazioni audio cifrate, condivisibili in gruppi a zero-knowledge.

Specifica, architettura e regole di sviluppo: [CLAUDE.md](CLAUDE.md).

## Avvio rapido

```bash
flutter pub get
dart analyze --fatal-infos
dart run tool/architecture_guard/bin/architecture_guard.dart
(cd apps/modusnote && flutter run)
```
