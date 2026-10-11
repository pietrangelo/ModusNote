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
* **Icona app:** squircle su `#090C15` con il solo monogramma "M" ingrandito del 20 %, senza linee di costruzione, con un leggero glow radiale viola/oro dietro la spirale. Per generarla serve il monogramma in formato vettoriale (SVG).
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
* **Limiti noti:** il registro dei membri è firmato ma non cifrato, quindi il server vede chiavi pubbliche e ruoli (non nomi né contenuti). Un membro può bloccare la sync scrivendo spazzatura nella prossima `sequence` del registro: i client la rifiutano e la sync si ferma (DoS, non perdita di riservatezza).
* **Piano gratuito di Supabase:** un progetto Free inattivo per una settimana viene sospeso. Il client deve gestire un backend temporaneamente non raggiungibile (offline-first lo rende naturale); in produzione va valutato il piano a pagamento.

---

## 1. PARADIGMI DI SVILUPPO VINCOLANTI

Ogni iterazione di codice eseguita da Claude CLI DEVE aderire rigorosamente a quattro pilastri:

### A. Domain-Driven Design (DDD)
* **Ubiquitous Language:** I termini di dominio (`SchemaDefinition`, `DynamicEntry`, `EncryptedEnvelope`, `KeyBundle`, `Vault`, `WorkspaceMember`) devono essere identici tra codice, test e documentazione.
* **Bounded Contexts espliciti:**
  1. `Identity & Cryptography`: Coppie di chiavi asimmetriche (X25519/Ed25519), derivazione chiavi (Argon2id), buste simmetriche (XChaCha20-Poly1305).
  2. `Schema & Dynamic Content`: Motore meta-modello per definire tipi, proprietà, vincoli e widget (nessun tipo hardcodato nel database).
  3. `Blob Storage & Media`: Lifecycle di registrazione, compressione locale, cifratura a blocchi e streaming di file audio.
  4. `Collaboration & Access Control`: Spazi condivisi, ratcheting crittografico, rotazione delle `GroupKey`.
  5. `Offline Sync`: Revisioni firmate e cifrate dei record, risoluzione dei conflitti, coda offline e motore di sincronizzazione.
* **Integrità del Dominio:** Nessun framework (Flutter/React/SQLite) può contaminare le entità e i value object del dominio. Il Dominio è puro.

### B. Rosette of Beautiful Code (Artigianato e Purezza)
* **Simmetria Architetturale:** Ogni bounded context deve esporre la medesima struttura a rosetta: un nucleo puro immutabile (Entities/VO), un anello di applicazione (Use Cases/Ports), e petali esterni sostituibili (Adapters/Infrastructure).
* **Immutabilità Totale:** Nessun side-effect all'interno delle entità. Le transizioni di stato producono nuove istanze validate.
* **Minimalismo Espressivo:** Nessuna complessità accidentale. Preferire composizione a ereditarietà profonda. I tipi devono rendere gli stati non validi non rappresentabili a livello di compilazione (*Make illegal states unrepresentable*). In Dart: `sealed class`, `final class`, costruttori privati con factory validanti, `extension type` per i Value Object.
* **Trasparenza Tipografica:** Naming preciso e autoesplicativo. I commenti spiegano solo il *perché* architetturale, mai il *cosa*.

### C. Test-Driven Development (TDD)
* **Ciclo Vincolante:** Red → Green → Refactor. Nessuna riga di codice di produzione viene scritta prima di un test fallito corrispondente.
* **Piramide dei Test:**
  * *Unit Tests (Pure Domain):* Istantanei, 100% deterministici, zero mock esterni.
  * *Property-Based Tests (in Dart: `glados`):* Verifica di invarianti crittografiche e serializzazione schemi su migliaia di input casuali.
  * *Integration Tests:* Persistenza su SQLite reale (solo buste cifrate) e pipeline audio reale su mock filesystem.

### D. The Adversary (Proactive Red-Teaming)
* Per ogni feature implementata, Claude CLI deve assumere il ruolo dell'**Avversario** ed eseguire un passaggio di stress test:
  1. *Fuzzing:* Iniezione di payload corrotti, chiavi parziali, JSON malformati nel parser dinamico.
  2. *Replay & Tampering Attacks:* Modifica di ciphertext o Nonce per validare il fallimento immediato dell'autenticazione crittografica (AEAD fail-fast).
  3. *Side-Channel & Zeroization Check:* Le chiavi private e le password in memoria devono essere protette, sovrascritte e mai esposte nei log di debug o crash report.
  4. *Zero-Knowledge Server Invariant:* Assicurarsi che nessuna operazione lato server o di sincronizzazione richieda o riceva payload o schemi in chiaro.
* I test avversari stanno in un gruppo `group('adversary', ...)` accanto ai test della feature.

### Vincolo di memoria (Dart)
Il garbage collector di Dart sposta e copia gli oggetti nell'heap, quindi un `Uint8List` contenente una chiave **non può essere azzerato in modo garantito**. Regole:
* Chiavi private, MasterKey, GroupKey e password derivate vivono solo in memoria nativa (`SecureKey` del pacchetto `sodium`, allocata con `sodium_malloc`/`sodium_mlock`) e vengono rilasciate con `dispose()` appena possibile.
* Il dominio rappresenta il materiale segreto con tipi opachi (Port) che non espongono mai i byte come `Uint8List` né tramite `toString()`.
* Nessun segreto passa per `String` (immutabile e non azzerabile), log, eccezioni o crash report.

---

## 2. CORE DOMAIN: IL MOTORE A SCHEMI DINAMICI (NON-STATICO)

Le interfacce (Canzone, Sogno, To-do, Appunto) **non sono tabelle o view statiche**, ma istanze di `SchemaDefinition` interpretate a runtime.

```text
[ SchemaDefinition (Meta-Model) ]
          │
          ├── Fields: List<FieldDefinition>   (key, label, required, type)
          │     └── FieldType (sealed): TextFieldType, RichTextFieldType, MarkdownFieldType,
          │           NumberFieldType, DateFieldType, DateTimeFieldType, BooleanFieldType,
          │           RatingFieldType, ChoiceFieldType (select / enum / status),
          │           TagListFieldType, AudioBlobFieldType
          └── UIHints: List<WidgetPlacement>

[ DynamicEntry (Aggregate Root) ]
          │
          ├── SchemaId (UUID + Version)
          ├── Attributes: Map<FieldKey, FieldValue>   (FieldValue sealed, uno per tipo)
          ├── AudioBlobValue → BlobId (i BlobMetadata vivono nel contesto Blob Storage)
          └── AuditTrail: CreatedAt, UpdatedAt, Revision
```

Transizioni (`create`, `update`, `SchemaMigration.migrate`) restituiscono `Validated<DynamicEntry>`:
`Valid` con la nuova istanza oppure `Invalid` con tutte le `Violation`. Gli schemi invalidi
non sono costruibili (`InvalidSchemaException`); `SchemaCodec.decode` lancia solo
`SchemaFormatException`.

### Schemi di Riferimento Predefiniti (Seed Data)
1. `song_sketch_v1`: Titolo (Text), Bpm (Number), Chiave (Select), Testo (RichText), TracciaGuida (AudioBlob).
2. `dream_log_v1`: Titolo (Text), DataSogno (Date), LivelloLucidità (Rating 1-5), Trascrizione (RichText), AudioSveglia (AudioBlob).
3. `task_v1`: Descrizione (Text), Scadenza (DateTime), Priorità (Enum), Completato (Boolean).
4. `quick_note_v1`: Contenuto (Markdown), Tag (TagList).

---

## 3. ARCHITETTURA CRITTOGRAFICA (E2EE A GRUPPI)

```text
               ┌───────────────────────┐
               │    Local MasterKey    │  (Derivata da Argon2id + Biometria)
               └───────────┬───────────┘
                           │ Cifra
               ┌───────────▼───────────┐
               │ User Identity Keypair │  (X25519 / Ed25519)
               └───────────────────────┘
                           │
      ┌────────────────────┴────────────────────┐
      ▼ (Condivisione Spazio/Gruppo)             ▼
┌───────────────┐                        ┌───────────────┐
│ GroupKey (Sym)│ ── Cifrata con PubKey ─▶   Membro B    │
└───────┬───────┘   del Membro B         └───────────────┘
        │
        ├── Cifra Record Metadata & Schema Data (XChaCha20-Poly1305)
        └── Deriva BlobKeys per cifrare blocchi Audio (.enc)
```

### Formato dei blob cifrati (`.enc`)
* **BlobKey:** una per blob, derivata dalla chiave dei contenuti con `crypto_kdf` (contesto `mn-blob1`, `SubkeyId` casuale di 8 byte salvato in chiaro nel `SealedBlob`). La sottochiave nasce direttamente in memoria nativa.
* **Chunk:** il plaintext è diviso in chunk da 64 KiB; ogni chunk è una busta XChaCha20-Poly1305 indipendente, preceduta da una lunghezza `uint32`. I dati associati legano il blob, l'indice del chunk e il flag "ultimo" (costruzione STREAM): riordino, chunk presi da un altro blob e coda tagliata falliscono l'autenticazione o vengono segnalati come `TruncatedBlobException`. Ogni chunk si decifra da solo, quindi seek e download parziali da R2 restano possibili.
* **Scrittura atomica:** si scrive in `<id>.enc.part` e si rinomina in `<id>.enc` al commit; un errore o un annullamento cancella il file parziale, e `discardIncomplete()` all'avvio rimuove quelli lasciati da un crash. Su disco e su R2 c'è solo ciphertext.
* **`BlobMetadata`** (formato audio, durata, data, `SealedBlob`) viaggia solo dentro i payload cifrati delle note; il `DynamicEntry` contiene soltanto il `BlobId`.

### Spazi condivisi e GroupKey (decisione del 2026-10-11)
* **Identità di dispositivo:** ogni dispositivo (mobile o web) ha una `IdentityKeyPair` con chiave di firma Ed25519 e chiave di incapsulamento **X-Wing** (`crypto_kem` di libsodium, ML-KEM-768 + X25519, ibrida post-quantistica: una GroupKey sigillata oggi protegge note per anni). Il `MemberId` è la chiave di firma, quindi il server non può rimappare chi è chi.
* **Incapsulamento:** `KeyEncapsulation` sigilla una `SymmetricKey` per un destinatario (`SealedKey` = ciphertext X-Wing + busta XChaCha20-Poly1305 con il segreto condiviso). I dati associati legano workspace, epoca e destinatario. L'incapsulamento è anonimo: chi ha emesso una chiave lo dice solo la firma del `KeyBundle`.
* **Registro dei membri:** ogni modifica (`WorkspaceFounded`, `MemberInvited`, `MemberRevoked`, `RoleChanged`) è un `MembershipRecord` firmato dall'autore e concatenato alla firma del record precedente. Il client ricostruisce il `Workspace` solo dal registro verificato (`VerifiedLedger`), a partire dal fondatore fissato nell'`Invitation` ricevuta fuori banda (QR o link). Il server conserva byte opachi e non può inserire, alterare, riordinare o mescolare record.
* **Ruoli:** solo gli `owner` gestiscono i membri ed emettono chiavi; `viewer` non scrive contenuti. Deve restare almeno un owner.
* **Epoche e rotazione:** la `GroupKey` ha un'epoca (`KeyEpoch`). Una revoca da parte di un owner avanza l'epoca e genera subito una nuova chiave, sigillata solo a chi resta. Chi esce da solo (`leave`) non ruota, perché conoscerebbe la nuova chiave: lo fa un owner con `rotate`, e finché la chiave non c'è nessuno scrive. I nuovi membri ricevono tutte le epoche, così leggono lo storico.
* **`KeyBundle`:** firmato da un owner, indica la posizione del registro in cui l'emittente agisce (`atSequence`). Si accetta solo se l'emittente era owner in quella posizione e se le epoche concesse esistevano già lì: un owner revocato non può usare una vecchia posizione per distribuire la chiave di un'epoca successiva. Per un'epoca già posseduta vale la prima chiave ricevuta.
* **Contenuti:** `WorkspaceContentCipher` cifra con la chiave dell'epoca corrente; `WorkspaceCiphertext` = epoca in chiaro + busta, con dati associati `(workspace, epoca, recordId)`.
* **Limiti noti:** chiusi in Fase 5 (vedi "Sincronizzazione") il rollback del registro, le scritture con epoche superate e il salvataggio dell'identità. Restano: i ruoli sui contenuti sono applicati da client e RLS, non dalla crittografia; un fork del registro che nessun altro membro cita resta invisibile finché un dispositivo non lo confronta.

### Sincronizzazione (decisione del 2026-10-11)
* **Revisione:** ogni modifica è una `RecordRevision` (record, workspace, `VersionVector`, autore, `writtenAt` UTC, `LedgerHead`, contenuto o cancellazione), firmata dall'autore (`SignedRevision`) e poi sigillata con la GroupKey. Il server vede solo `RecordId`, workspace, epoca e ciphertext.
* **Server append-only:** righe, record del registro e `KeyBundle` si aggiungono e non si sovrascrivono mai. Ogni client vede tutte le revisioni e risolve da solo i conflitti: `ConflictResolver` applica il vector clock; per revisioni concorrenti vince `writtenAt` più recente, poi la chiave dell'autore. Tutti i dispositivi convergono sullo stesso vincitore. Le cancellazioni sono revisioni (tombstone), quindi una copia vecchia non le annulla.
* **Autenticazione (`RevisionAuthenticator`):** firma dell'autore; l'autore poteva scrivere nella posizione del registro che cita e può ancora scrivere oggi; l'epoca del ciphertext è quella in vigore in quella posizione. Un membro revocato, pur avendo le chiavi vecchie, non fa accettare nulla di nuovo. Una sua modifica offline fatta prima della revoca, ma sincronizzata dopo, va persa.
* **Rollback e fork del registro:** ogni revisione cita l'ultimo record del registro visto dall'autore (`LedgerHead`: posizione + firma). Se il server non sa mostrare quel record, o ne mostra uno diverso, la sync si ferma con `LedgerRollbackException`.
* **Offline first:** `SyncEngine.write` salva subito in locale e mette la riga già sigillata nella `Outbox`; `sync` spinge la coda nell'ordine di scrittura, aggiorna registro e chiavi, poi scarica le righe nuove. Senza rete restituisce `offline` e la coda resta intatta.
* **Database locale:** contiene solo buste. I record sono sigillati con una chiave locale del dispositivo (derivata dalla MasterKey), con dati associati (workspace, record); la coda contiene solo righe già cifrate con la GroupKey.
* **Niente SQLCipher (decisione del 2026-10-11):** mobile e web usano lo stesso SQLite (`package:sqlite3`, API comune nativa e WASM) con `PRAGMA secure_delete`. Il contenuto è già cifrato dal dominio; SQLCipher proteggerebbe solo id e conteggi, solo su mobile, e la sua chiave passerebbe da una stringa `PRAGMA`. Il binario nativo di SQLite è scaricato dal build hook di `sqlite3` con hash SHA-256 fissati nel pacchetto.
* **Identità:** `IdentityService.sealIdentity` salva i due seed (Ed25519 e X-Wing) cifrati con la MasterKey; le chiavi pubbliche si ricavano dai seed.

---

## 4. FASI DI SVILUPPO

### Fase 1: Pure Crypto Core & Memory Safety
* Obiettivo: Costruire il modulo crittografico isolato con libsodium.
* Task TDD:
   1. `KeyDerivationService`: Test per Argon2id con salt univoci e parametri di memoria robusti.
   2. `EnvelopeEncryptor`: Test simmetrici XChaCha20-Poly1305.
   3. `Adversary Harness`: Test con mutazione di 1 singolo bit del ciphertext → verificare eccezione `AuthenticationTagMismatchException`.
   4. Test di zeroizzazione esplicita della memoria dopo l'uso delle chiavi private.

### Fase 2: Dynamic Schema & Entity Aggregate
* Obiettivo: Motore per la composizione dinamica dei campi e validazione a runtime.
* Task TDD:
   1. Definizione e validazione di `SchemaDefinition` (campi obbligatori, tipi primitivi, tipi composti).
   2. Creazione dell'aggregato `DynamicEntry`: verifica che un'istanza rispetti i vincoli del suo schema corrispondente.
   3. Supporto al versionamento dello schema: test di migrazione da `schema_v1` a `schema_v2`.
   4. `Adversary Harness`: Fuzzing del parser dello schema con stringhe JSON corrotte, campi ricorsivi infiniti e type-confusion attacks.

### Fase 3: Encrypted Blob Engine (Audio & Media)
* Obiettivo: Gestione offline-first delle registrazioni audio cifrate.
* Task TDD:
   1. `AudioRecordingSession`: Contratto per acquisizione come `Stream<Uint8List>` (nessun percorso di file), compressione (Opus dove disponibile) e cifratura per chunk.
   2. `EncryptedBlobStorage`: Chunking e cifratura simmetrica in streaming del file prima del salvataggio su disco locale e del caricamento su Cloudflare R2.
   3. Associazione tra `BlobMetadata` e l'attributo `AudioBlobField` del `DynamicEntry`.
   4. `Adversary Harness`: Verifica che file audio parziali, interrotti o corrotti non crashino il decifratore e non lascino mai frammenti temporanei non cifrati nella directory di cache.

### Fase 4: Bounded Context Groups & Envelope Encryption
* Obiettivo: Condivisione sicura di note e schemi con crittografia asimmetrica.
* Task TDD:
   1. `WorkspaceAggregate`: Gestione di membri, ruoli e `GroupKey`.
   2. Generazione di inviti e rotazione della `GroupKey` quando un membro viene revocato (Forward Secrecy).
   3. Test di incapsulamento della chiave per ogni membro destinatario.
   4. `Adversary Harness`: Un membro rimosso tenta di decifrare una revisione successiva della nota; il server malevolo tenta di iniettare una nuova chiave pubblica senza firma valida.

### Fase 5: Local Persistence & Offline Sync Engine
* Obiettivo: Salvataggio su database locale di soli record cifrati (SQLite nativo su mobile, SQLite WASM su web) e coda di sincronizzazione verso Supabase.
* Task TDD:
   1. Mapping tra aggregati di dominio ed entità persistenti cifrate.
   2. Risoluzione dei conflitti (CRDT-based o Last-Write-Wins con vector clocks) mantenendo i payload cifrati.
   3. Queue di sincronizzazione offline: le operazioni eseguite senza rete vengono accodate, cifrate e applicate in ordine al ripristino della connessione.
   4. `Adversary Harness`: le righe scritte su Supabase e gli oggetti su R2 non contengono plaintext; un utente non membro non legge le righe di un vault (test delle policy RLS).

### Fase 6: Dynamic UI Renderer & Interaction
* Obiettivo: Interfaccia dinamica che compone i componenti visivi in base allo schema caricato.
* Task TDD / Component Test:
   1. `DynamicFormRenderer`: Generazione dinamica dei widget in base allo schema (Waveform player per tracce audio, editor testuale per testi, picker data/metadati).
   2. Generazione e testing dei 4 template iniziali (Canzone, Sogno, Task, Nota), con etichette localizzate.
   3. Modalità rapida per il passaggio da una tipologia di nota all'altra e ricerca su metadati locali indicizzati in chiaro (solo indici sicuri/tag anonimizzati).

### Fase 7: Web Client
* Obiettivo: Il client web come alternativa all'app mobile, sincronizzato con essa.
* Task TDD:
   1. Adapter crypto web: inizializzazione di libsodium WASM e stessi test dell'adapter nativo eseguiti con `dart test -p chrome`.
   2. Persistenza web: SQLite WASM su OPFS con soli record cifrati; test che nessun plaintext raggiunga lo storage del browser.
   3. Sblocco web: passphrase per sessione e WebAuthn PRF; blocco automatico alla chiusura o dopo inattività.
   4. Hardening: CSP, SRI e build senza CDN, verificati in CI.
   5. `Adversary Harness`: script iniettato che cerca chiavi in storage persistente, tab rimasta aperta dopo il blocco, risorsa servita senza integrità valida.

---

## 5. COMANDI OPERATIVI PER L'AGENTE

Prima di scrivere qualsiasi codice, Claude CLI deve eseguire la suite esistente, scrivere il test fallito per il task selezionato, implementare il codice minimo per farlo passare, e lanciare la verifica avversaria.

```text
# Regola aurea ad ogni step:
1. RUN_TESTS          -> Fallimento atteso (RED)
2. IMPLEMENT_CODE     -> Codice minimo pulito, DDD-compliant
3. RUN_TESTS          -> Tutti i test passano (GREEN)
4. RUN_ADVERSARY_SUITE -> Stress/Fuzz/Tamper test passano
5. REFACTOR           -> Applica simmetria e pulizia Rosette
```

Prima di ogni commit: `dart analyze --fatal-infos`, architecture guard e tutte le suite devono essere verdi.
