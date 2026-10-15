# ModusNote

Note offline-first, cifrate end-to-end, con un motore a schemi dinamici (canzoni, sogni, to-do, note libere) e registrazioni audio cifrate, condivisibili in gruppi a zero-knowledge.

Specifica, architettura e regole di sviluppo: [CLAUDE.md](CLAUDE.md).

## Architettura

### Rete

Telefoni e browser sono gli unici a tenere chiavi e testo in chiaro. Cloudflare Pages serve il bundle web, Supabase (Auth, PostgREST con RLS, Edge Functions) sincronizza righe cifrate e firma gli URL per R2, Cloudflare R2 conserva registrazioni e immagini cifrate: tutti e tre vedono solo ciphertext.

![Architettura di rete: dispositivi, Cloudflare Pages, Supabase, Cloudflare R2, GitHub Actions e Google Play](docs/architettura-rete.svg)

### Applicazione

Un pacchetto Dart puro per bounded context, con i port nel dominio e gli adapter (libsodium, SQLite, Supabase, R2, libopus, WebCodecs) in pacchetti `_adapters` separati; l'app Flutter li collega in `lib/bootstrap/`.

![Architettura applicativa: app Flutter, cinque bounded context, adapter, gerarchia delle chiavi e salvataggio di una nota](docs/architettura-applicativa.svg)

## Avvio rapido

```bash
flutter pub get
dart analyze --fatal-infos
dart run tool/architecture_guard/bin/architecture_guard.dart
(cd apps/modusnote && flutter run)
```
