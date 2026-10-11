# ModusNote

## MISSION
Costruire un'applicazione mobile e web offline-first e crittografata end-to-end (E2EE) con motore a tipi dinamici (schemi estensibili per canzoni, sogni, to-do, note libere) e gestione di blob audio cifrati, sincronizzabile in gruppi a zero-knowledge.

- **Stack:** Flutter (Dart 3.13+), pub workspace. Un'unica app per Android, iOS e **web** (Flutter Web, WebAssembly), che riusa gli stessi pacchetti di dominio.
- **Dominio dell'app:** `modus.serv.run`. Identificativo Android/iOS: `run.serv.modus`.
- **Lingue:** l'app è multi-lingua fin dal primo commit (italiano e inglese per iniziare).

---

## 0. STRUTTURA DEL REPOSITORY E COMANDI

```text
apps/modusnote/                      Shell Flutter (Android, iOS, web): UI, l10n, wiring degli adapter. Nessuna logica di dominio.
packages/identity_cryptography/      Bounded context (dominio puro)
packages/schema_dynamic_content/     Bounded context (dominio puro)
packages/blob_storage_media/         Bounded context (dominio puro)
packages/collaboration_access_control/ Bounded context (dominio puro)
packages/offline_sync/               Bounded context (dominio puro): revisioni firmate, conflitti, coda offline
packages/identity_cryptography_adapters/ Adapter libsodium (pacchetto `sodium`, variante sumo per Argon2id)
packages/blob_storage_media_adapters/  Storage dei blob cifrati (filesystem tramite `package:file`), muxer Ogg Opus, encoder libopus (FFI + build hook)
packages/blob_storage_media_recorder_adapters/ Microfono tramite il plugin `record` (pacchetto Flutter, test con `flutter test`)
packages/offline_sync_adapters/      Database locale SQLite (stessa API nativa e WASM): solo buste cifrate; `SupabaseSyncServer` (PostgREST via `package:http`)
packages/<context>_adapters/         Altri petali esterni, creati quando servono
tool/architecture_guard/             Verifica statica delle regole della rosetta
```

Ogni pacchetto di dominio ha la stessa forma:

```text
lib/<context>.dart        API pubblica: l'unico file che altri pacchetti possono importare
lib/src/core/             Entities e Value Object immutabili. Solo dart:core/typed_data/collection/math/convert e package:meta.
lib/src/application/      Use Case e Port. Può usare core e dart:async, nient'altro.
```

Gli adapter **non** vivono in `lib/src/adapters/` del pacchetto di dominio: vanno in un pacchetto separato `<context>_adapters`, così le dipendenze di framework non possono entrare nel dominio nemmeno per sbaglio. `tool/architecture_guard` fa fallire la CI se:
- `core` importa qualcosa al di fuori di `core` e delle librerie consentite;
- `application` importa framework, I/O o pacchetti di terze parti;
- un pacchetto di dominio dichiara dipendenze diverse da `meta` o da altri pacchetti di dominio;
- un pacchetto importa i file `src/` di un altro pacchetto.

`core` e `application` possono importare l'API pubblica (`lib/<context>.dart`) di un altro pacchetto di dominio dichiarato in `dependencies`, mai quella di un pacchetto `_adapters`.

Comandi (dalla radice):

```bash
flutter pub get                                   # risolve tutto il workspace e rigenera le l10n
dart analyze --fatal-infos                        # zero warning ammessi
dart run tool/architecture_guard/bin/architecture_guard.dart
(cd packages/<context> && dart test)              # test di un bounded context
(cd tool/architecture_guard && dart test)
(cd apps/modusnote && flutter test)
bash supabase/tests/run.sh                        # migrazioni + test RLS su un PostgreSQL usa e getta
bash supabase/tests/e2e.sh                        # SupabaseSyncServer contro un PostgREST reale (hash fissato; MODUSNOTE_POSTGREST per offline)
node --test "supabase/functions/**/*_test.ts"      # Edge Function (Node 22.18+, TypeScript senza build)
```

Il pacchetto `sodium` compila libsodium dai sorgenti tramite build hook al primo `dart test` (serve un compilatore C e accesso a `download.libsodium.org`; la prima esecuzione richiede ~30 s).

### Localizzazione
- Le stringhe dell'app vivono in `apps/modusnote/lib/l10n/app_<lingua>.arb` (template `app_en.arb`). Nessuna stringa visibile all'utente scritta a mano nei widget.
- Il dominio non contiene testo localizzato. Gli schemi seed referenziano le etichette dei campi tramite **chiavi** (es. `schema.song_sketch.field.bpm`), che la UI risolve con `AppLocalizations`. Gli schemi creati dall'utente portano l'etichetta scritta dall'utente così com'è.
- Una nuova lingua si aggiunge con un nuovo file ARB e, su iOS, una voce in `CFBundleLocalizations` di `ios/Runner/Info.plist`.

### Interfaccia grafica: rapporto aureo (regola permanente)
Tutta la UI si costruisce **sempre** sul rapporto aureo φ = 1,618…:
- **Spaziature:** scala geometrica di ragione φ a partire da una base di 8 dp (≈ 3, 5, 8, 13, 21, 34, 55 dp). Nessun valore di padding o margine fuori scala.
- **Tipografia:** scala modulare di ragione φ: didascalia 10 sp, corpo 16 sp, titolo 2 26 sp, titolo 1 42 sp, display 68 sp.
- **Layout:** le suddivisioni di schermo e colonne seguono 61,8 % / 38,2 %; contenitori e card usano proporzioni φ : 1 (orizzontali) o 1 : φ (verticali).
- **Raggi, icone e larghezze di riga** prendono i valori dalla stessa scala.
- I valori vivono in un unico set di design token (`apps/modusnote/lib/theme/`); i widget non scrivono numeri a mano. I test di componente verificano che le dimensioni usate appartengano alla scala.

### Identità visiva (decisione del 2026-10-11)
Il marchio, e il nome visibile dell'app (titolo, nome sotto l'icona, pagina web), è **Modus Notes**, sottotitolo "Modo · Misura · Ritmo". Il simbolo unisce la M, una nota musicale (ritmo), la spirale aurea (misura) e un segno di spunta (to-do). Il logo è in `apps/modusnote/assets/brand/`.

| Ruolo UI | Nome | HEX | Uso |
|---|---|---|---|
| Background | Deep Void | `#090C15` | Sfondo principale (l'app è dark nativa) |
| Surface | Abyssal Slate | `#13192B` | Card, menu laterali, fogli modali |
| Primary | Aureo Gold | `#EBB448` | Azioni principali, note salvate, focus; testo sopra in Deep Void |
| Secondary | Rhythm Violet | `#8B3FD6` | Ritmo/metronomo, tag audio, categorie; **solo come riempimento**, testo sopra in Pure Mist |
| Secondary (testo) | Rhythm Violet tint | `#A265DE` | Testo e icone viola su sfondi scuri (il viola pieno arriva a 3,2:1, sotto AA) |
| Success | Cadence Cyan | `#00A3FF` | Checkbox spuntate, scadenze completate; testo sopra in Deep Void |
| Text | Pure Mist | `#F8FAFC` | Titoli e testo delle note |
| Text muted | Dust Silver | `#8F9CAE` | Timestamp, sottotitoli, linee secondarie |

* **Font:** Plus Jakarta Sans per i titoli, Inter per il corpo. Entrambi sono SIL OFL e sono inclusi in `apps/modusnote/assets/fonts/` (nessun font scaricato a runtime). Satoshi è stato scartato perché la sua licenza non permette di includerlo liberamente nel bundle.
* **Contrasto:** ogni coppia testo/sfondo deve raggiungere WCAG AA (4,5:1); `test/theme_test.dart` lo verifica.
* **Icona app:** il monogramma vettoriale è `assets/brand/modus_monogram.svg` (M come nota musicale, spirale aurea, spunta; gradiente oro → viola → ciano). `assets/brand/modus_app_icon.svg` lo mette su `#090C15` con un glow radiale viola/oro, a tutto campo, con il monogramma dentro la zona sicura dell'80 % (iOS e le icone maskable applicano la propria maschera). I PNG di Android, iOS e web si rigenerano con `python3 tool/render_icons.py` da `apps/modusnote` (Chromium headless + ImageMagick) e sono committati, quindi la build non dipende da questi strumenti.
* I token vivono in `apps/modusnote/lib/theme/` (`golden_ratio.dart`, `modus_colors.dart`, `modus_theme.dart`).

### Client web
Il client web è un'alternativa completa all'app mobile e si sincronizza con essa: per il protocollo di sync è semplicemente un altro dispositivo del vault, con la propria coppia di chiavi di identità. Si compila con `flutter build web --wasm --no-web-resources-cdn` (nessuna risorsa caricata da CDN di terzi: CanvasKit e font fanno parte del bundle servito da Cloudflare Pages).

Nel browser alcune garanzie cambiano, e il codice deve tenerne conto in modo esplicito:
* **Memoria delle chiavi:** non esistono `sodium_malloc`/`mlock`. Su web `SecureKey` è un buffer JS che viene azzerato al `dispose()`, ma il motore JS può averne fatto copie. La regola "dispose il prima possibile" resta, ma la garanzia è più debole che su mobile.
* **Fiducia nel codice:** il server che distribuisce l'app web potrebbe servire codice malevolo a ogni caricamento. Mitigazioni obbligatorie: Content-Security-Policy restrittiva (niente script inline o di terze parti, solo `wasm-unsafe-eval`), Subresource Integrity, nessuna dipendenza da CDN, hash delle build pubblicati.
* **XSS ed estensioni:** qualunque script iniettato vede le chiavi in memoria. Niente HTML generato da contenuti utente (Markdown e testo arricchito sono renderizzati come widget, mai come HTML).
* **Persistenza:** niente SQLCipher. Il database locale è SQLite WASM su OPFS/IndexedDB e contiene solo record già cifrati con le buste del dominio. Le chiavi non si salvano mai in `localStorage`/IndexedDB in chiaro.
* **Sblocco:** niente biometria nativa. La MasterKey si ottiene con la passphrase a ogni sessione oppure tramite WebAuthn con estensione PRF, dove disponibile.
* **Crypto:** libsodium arriva via WebAssembly (backend JS del pacchetto `sodium`, variante sumo per Argon2id). Non si usa WebCrypto, che non offre XChaCha20-Poly1305 né Argon2id.

### Codice per piattaforma (mobile e web)
Il dominio non sa su quale piattaforma gira. Le differenze tra Dart nativo (VM/AOT, `dart:io`, `dart:ffi`) e web (JS/WASM, `dart:js_interop`) restano negli adapter:
* **Ports & Adapters + conditional imports.** Quando un adapter ha bisogno di API diverse per piattaforma, il pacchetto `<context>_adapters` espone una factory che sceglie l'implementazione con `import 'x_stub.dart' if (dart.library.io) 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';`. Lo stub lancia `UnsupportedError`. Nei pacchetti di dominio i conditional imports sono vietati (regola `conditionalImport` dell'architecture guard).
* **libsodium.** L'app usa `sodium_libs` (plugin Flutter: FFI su Android/iOS, `sodium.js`/WASM su web, installato con `dart run sodium_libs:update_web`). Gli adapter dipendono solo dal pacchetto `sodium` puro e ricevono l'istanza `SodiumSumo` già inizializzata nel costruttore. L'inizializzazione asincrona (necessaria sul web per caricare il WASM) avviene una sola volta all'avvio dell'app, quindi non esiste un adapter "non ancora inizializzato".
* **Le API crypto restano quelle del dominio.** Si usano solo i port `EnvelopeEncryptor` e `KeyDerivationService`: XChaCha20-Poly1305 AEAD con `AssociatedData` obbligatoria, nonce generato dall'adapter e chiavi come handle opachi (`SymmetricKey`). Non si usano `secretBox` (nessun dato associato, quindi nessun legame al record), né chiavi o nonce passati come `Uint8List`.
* **Audio come flusso di byte, mai come percorso di file.** Il port di registrazione restituisce `Stream<Uint8List>`, con chunk cifrati appena prodotti, così su nessuna piattaforma esistono file audio in chiaro. Implementazione con il pacchetto `record` (`startStream`). Nota: lo streaming di `record` produce PCM, quindi la compressione Opus va fatta dall'adapter (libopus via FFI su mobile, WebCodecs `AudioEncoder` su web). Safari non registra Opus/WebM con `MediaRecorder`; il formato effettivo va negoziato per piattaforma e salvato nei metadati cifrati del blob.
* **Permessi microfono:** Android `RECORD_AUDIO` in `AndroidManifest.xml`; iOS `NSMicrophoneUsageDescription` in `Info.plist`, localizzata in `ios/Runner/<lingua>.lproj/InfoPlist.strings`; web nessun manifest, ma solo su HTTPS (o `localhost`), con richiesta del browser a runtime.
* **Opus (decisione del 2026-10-11):** libopus si compila dai sorgenti ufficiali tramite il build hook di `blob_storage_media_adapters` (versione e SHA-256 fissati in `hook/build.dart`; la CI confronta l'hash con `SHA256SUMS.txt` di xiph.org). I binding FFI sono nostri e minimi, e i `ctl` variadici passano da un piccolo shim C. Nessun wrapper di terze parti. Per build offline: `MODUSNOTE_OPUS_ARCHIVE=/percorso/opus-<versione>.tar.gz` (l'hash viene verificato comunque). Sul web, finché non arriva l'encoder WebCodecs (Fase 7), la cattura produce WAV PCM16 non compresso.

### Infrastruttura (decisione del 2026-10-11)
| Componente | Servizio | Cosa vede il servizio |
|---|---|---|
| Client web | **Cloudflare Pages** (file statici; build in GitHub Actions, perché l'ambiente di build di Pages non include Flutter, poi `wrangler pages deploy`) | Solo il bundle dell'app |
| Blob audio cifrati | **Cloudflare R2** (S3-compatibile, nessun costo di egress) | Solo chunk `.enc` e la loro dimensione |
| Sync e account | **Supabase** (PostgreSQL + Auth) | Righe cifrate, id, revisioni, timestamp; l'email dell'account |

L'invariante zero-knowledge vale per tutti e tre i servizi: ricevono e restituiscono solo ciphertext prodotto dalle buste del dominio. Regole che ne derivano:
* **Auth e chiavi sono separati.** Supabase Auth autentica l'account (email/magic link o OAuth) per l'accesso alle righe. La passphrase del vault non viene mai inviata, né usata come password di Supabase. Se in futuro si userà un'unica password, la credenziale di login deve essere derivata dalla chiave Argon2id con una derivazione separata (KDF con contesto diverso), mai la passphrase stessa.
* **Row Level Security** obbligatoria su ogni tabella: un utente legge e scrive solo le righe dei vault di cui è membro.
* **Metadati minimi in chiaro:** id opachi, revisione, timestamp di sync, dimensione. Titoli, tipi di nota, tag e schemi stanno solo dentro i payload cifrati.
* **R2 tramite URL pre-firmati** emessi da una funzione lato server (Supabase Edge Function o Cloudflare Worker) dopo il controllo dell'autorizzazione. Le credenziali R2 non arrivano mai al client. CORS limitato al dominio dell'app.
* **Cloudflare Pages senza iniezioni:** vanno disattivate tutte le funzioni che modificano l'HTML servito (Rocket Loader, Web Analytics automatico, Email Obfuscation, Zaraz), perché romperebbero CSP e SRI. CSP e altri header si dichiarano in `apps/modusnote/web/_headers`.
* **Fiducia nel codice servito:** Cloudflare, o chiunque abbia accesso al deploy, può servire un bundle diverso. Per questo valgono le mitigazioni della sezione "Client web" (hash delle build pubblicati, build riproducibili).
* **Schema (`supabase/migrations/`):** `workspaces`, `workspace_accounts` (account Supabase ammessi, con `can_manage`), e tre flussi **append-only**: `sync_rows` (record_id, epoca, ciphertext), `membership_records` (registro firmato, `sequence` univoca) e `key_bundles`. Nessuno può fare UPDATE o DELETE sui flussi, nemmeno con una policy aggiunta per errore, perché il privilegio è revocato. Le posizioni sono assegnate dal server per workspace sotto lock, quindi crescono in ordine di commit e un client che legge `position > cursore` non salta righe. Revocare un dispositivo significa anche togliere il suo account da `workspace_accounts`.
* **Test RLS:** `supabase/tests/run.sh` applica le migrazioni a un PostgreSQL temporaneo con uno stub di `auth.uid()` ed esegue i test come ruolo `authenticated` con il `sub` del JWT, come fa PostgREST. Gira anche in CI.
* **Adapter Dart (`SupabaseSyncServer`):** parla con PostgREST (`/rest/v1/<tabella>`) tramite `package:http`, con la chiave anon pubblica e il token di sessione Supabase passato come callback (mai salvato né incluso nei messaggi d'errore). I `bytea` viaggiano come `\x` esadecimale. Le risposte sono input non fidato: posizioni non strettamente crescenti o registro di membership con buchi danno `MalformedSyncDataException`, una voce illeggibile viene scartata. Errori di rete, timeout, 5xx, 408 e 429 diventano `ServerUnavailableException` (il motore resta offline e riprova); gli altri rifiuti `SyncServerRejectedException(status)`. `supabase/tests/e2e.sh` lo prova contro PostgREST v12 e PostgreSQL veri (RLS, trigger, formati), anche in CI.
* **URL pre-firmati per R2 (`supabase/functions/blob-url`):** Edge Function senza dipendenze di terzi (firma SigV4 scritta con WebCrypto e verificata sul vettore d'esempio di AWS). Riceve `{workspace_id, blob_id, method}` con il token di sessione, chiede al database `is_workspace_account` *come il chiamante* (lo stesso helper delle policy RLS) e restituisce un URL valido 5 minuti per l'unico oggetto `<workspace>/<blob>.enc`. `GET` per leggere (anche a intervalli con `Range`), `PUT` solo per creare: l'URL è firmato con `If-None-Match: *`, quindi un membro non può sovrascrivere la registrazione di un altro. Nessun DELETE. I segreti `R2_*` si impostano con `supabase secrets set` e non lasciano mai la funzione; le risposte hanno messaggi fissi; CORS solo per `APP_ORIGIN` (predefinito `https://modus.serv.run`). Il CORS del bucket R2 deve ammettere la stessa origine e l'header `If-None-Match`. Limiti noti: un URL `PUT` pre-firmato non può imporre una dimensione massima (resta il limite di R2), e il rifiuto di sovrascrittura va confermato su un bucket reale al primo deploy.

### Vault del dispositivo
* **`VaultKeeper`:** `create` fonda uno spazio personale con una nuova identità di dispositivo, `unlock` lo riapre. La passphrase diventa la MasterKey (Argon2id) ed è consumata da ogni chiamata. La MasterKey sigilla l'identità e deriva la chiave locale dei record (`crypto_kdf`, contesto `mn-local`), poi viene rilasciata subito.
* **`VaultHeader`:** l'unico dato del vault in chiaro (salt, costi Argon2id entro soglia minima e massima, workspace, fondatore, `SubkeyId` della chiave locale, identità sigillata). Tutti i campi sono legati ai dati associati dell'identità, quindi un header alterato si comporta come una passphrase sbagliata (`WrongPassphraseException`).
* **Registro locale:** registro dei membri e `KeyBundle` salvati sul dispositivo (`SqliteVaultStore`, stesso file SQLite dei record, schema versionato in comune) vengono riverificati a ogni sblocco a partire dal fondatore dell'header. `lock()` rilascia identità, chiave locale e GroupKey.
* **Limite noto (Flutter):** la passphrase digitata passa per la `String` di un `TextField`, inevitabile. La UI la converte subito in `PasswordSecret` e svuota il controller.
