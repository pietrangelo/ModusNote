# Sicurezza

Per segnalare una vulnerabilità di Modus Notes (app, client web su modus.serv.run, funzioni server in `supabase/`), scrivi a gplay.suave928@passmail.net in italiano o in inglese, senza aprire una issue pubblica, oppure usa «Report a vulnerability» nella scheda Security del repository. Descrivi il problema, come riprodurlo e cosa permette a un attaccante.

Rispondo entro 7 giorni. Chiedo di non pubblicare dettagli finché la correzione non è distribuita, e comunque non prima di 90 giorni dalla segnalazione.

Rientrano soprattutto: lettura o falsificazione di note, registrazioni o chiavi; aggirare il registro firmato dei membri o la revoca; fughe di dati in chiaro verso server, log o disco; CSP, SRI e integrità del bundle web. Il modello di minaccia e i limiti noti sono in [CLAUDE.md](CLAUDE.md): un limite già elencato lì non è una vulnerabilità nuova, a meno che la segnalazione non mostri che è peggiore di quanto scritto.

Non ci sono ricompense in denaro.

---

To report a vulnerability, write to gplay.suave928@passmail.net (Italian or English) instead of opening a public issue. I answer within 7 days and ask for 90 days before disclosure. Known limits are listed in CLAUDE.md.
