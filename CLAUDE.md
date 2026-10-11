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
packages/identity_cryptography_adapters/ Adapter libsodium (pacchetto `sodium`, variante sumo per Argon2id)
packages/<context>_adapters/         Altri petali esterni (SQLCipher, Opus, ...), creati quando servono
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

Comandi (dalla radice):

```bash
flutter pub get                                   # risolve tutto il workspace e rigenera le l10n
dart analyze --fatal-infos                        # zero warning ammessi
dart run tool/architecture_guard/bin/architecture_guard.dart
(cd packages/<context> && dart test)              # test di un bounded context
(cd tool/architecture_guard && dart test)
(cd apps/modusnote && flutter test)
```

Il pacchetto `sodium` compila libsodium dai sorgenti tramite build hook al primo `dart test` (serve un compilatore C e accesso a `download.libsodium.org`; la prima esecuzione richiede ~30 s).

### Localizzazione
- Le stringhe dell'app vivono in `apps/modusnote/lib/l10n/app_<lingua>.arb` (template `app_en.arb`). Nessuna stringa visibile all'utente scritta a mano nei widget.
- Il dominio non contiene testo localizzato. Gli schemi seed referenziano le etichette dei campi tramite **chiavi** (es. `schema.song_sketch.field.bpm`), che la UI risolve con `AppLocalizations`. Gli schemi creati dall'utente portano l'etichetta scritta dall'utente così com'è.
- Una nuova lingua si aggiunge con un nuovo file ARB e, su iOS, una voce in `CFBundleLocalizations` di `ios/Runner/Info.plist`.

### Interfaccia grafica: rapporto aureo (regola permanente)
Tutta la UI si costruisce **sempre** sul rapporto aureo φ = 1,618…:
- **Spaziature:** scala geometrica di ragione φ a partire da una base di 8 dp (≈ 3, 5, 8, 13, 21, 34, 55 dp). Nessun valore di padding o margine fuori scala.
- **Tipografia:** scala modulare di ragione φ (es. corpo 16 sp → titolo 26 sp → display 42 sp; didascalia 10 sp).
- **Layout:** le suddivisioni di schermo e colonne seguono 61,8 % / 38,2 %; contenitori e card usano proporzioni φ : 1 (orizzontali) o 1 : φ (verticali).
- **Raggi, icone e larghezze di riga** prendono i valori dalla stessa scala.
- I valori vivono in un unico set di design token (`apps/modusnote/lib/theme/`); i widget non scrivono numeri a mano. I test di componente verificano che le dimensioni usate appartengano alla scala.

### Client web
Il client web è un'alternativa completa all'app mobile e si sincronizza con essa: per il protocollo di sync è semplicemente un altro dispositivo del vault, con la propria coppia di chiavi di identità. Si compila con `flutter build web --wasm --no-web-resources-cdn` (nessuna risorsa caricata da CDN di terzi: CanvasKit e font fanno parte del bundle servito da Cloudflare Pages).

Nel browser alcune garanzie cambiano, e il codice deve tenerne conto in modo esplicito:
* **Memoria delle chiavi:** non esistono `sodium_malloc`/`mlock`. Su web `SecureKey` è un buffer JS che viene azzerato al `dispose()`, ma il motore JS può averne fatto copie. La regola "dispose il prima possibile" resta, ma la garanzia è più debole che su mobile.
* **Fiducia nel codice:** il server che distribuisce l'app web potrebbe servire codice malevolo a ogni caricamento. Mitigazioni obbligatorie: Content-Security-Policy restrittiva (niente script inline o di terze parti, solo `wasm-unsafe-eval`), Subresource Integrity, nessuna dipendenza da CDN, hash delle build pubblicati.
* **XSS ed estensioni:** qualunque script iniettato vede le chiavi in memoria. Niente HTML generato da contenuti utente (Markdown e testo arricchito sono renderizzati come widget, mai come HTML).
* **Persistenza:** niente SQLCipher. Il database locale è SQLite WASM su OPFS/IndexedDB e contiene solo record già cifrati con le buste del dominio. Le chiavi non si salvano mai in `localStorage`/IndexedDB in chiaro.
* **Sblocco:** niente biometria nativa. La MasterKey si ottiene con la passphrase a ogni sessione oppure tramite WebAuthn con estensione PRF, dove disponibile.
* **Crypto:** libsodium arriva via WebAssembly (backend JS del pacchetto `sodium`, variante sumo per Argon2id). Non si usa WebCrypto, che non offre XChaCha20-Poly1305 né Argon2id.

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
  * *Integration Tests:* Persistence via SQLCipher e pipeline audio reale su mock filesystem.

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
          ├── Fields: List<FieldDefinition>
          │     ├── StringField, NumberField, DateField, AudioBlobField, StatusField
          └── UIHints: List<WidgetPlacementDescriptor>

[ DynamicEntry (Aggregate Root) ]
          │
          ├── SchemaId (UUID + Version)
          ├── Attributes: Map<FieldKey, ValueObject>
          ├── EncryptedBlobs: List<BlobMetadata>
          └── AuditTrail: CreatedAt, UpdatedAt, Revision
```

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
   1. `AudioRecordingSession`: Contratto per acquisizione stream, compressione (Opus) e buffer locale.
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
* Obiettivo: Salvataggio su database cifrato locale (SQLCipher su mobile, SQLite WASM su web) e coda di sincronizzazione verso Supabase.
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
