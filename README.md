# GassPlayer

> Un player IPTV nativo per iPhone e iPad, costruito in SwiftUI e progettato per riunire Live TV, VOD, Serie TV, EPG, catch-up, sorgenti multiple, metadata, preferiti, cronologia, download, controlli avanzati di riproduzione e gestione della rete in un'unica esperienza moderna.

GassPlayer è un'app iOS standalone per la gestione e la riproduzione di contenuti provenienti principalmente da **Xtream Codes** e **playlist M3U/M3U8**. Il progetto combina una UI SwiftUI con un player basato su **KSPlayer**, un catalogo persistente e cacheato, una gestione centralizzata delle sorgenti, integrazioni opzionali con servizi metadata/social, una guida TV EPG completa e una Network Extension dedicata alla VPN personale.

Il progetto è pensato per essere **native-first**, reattivo e configurabile: le sorgenti restano sotto il controllo dell'utente, i cataloghi vengono cacheati localmente, le preferenze sono persistenti e le operazioni di rete includono retry e diagnostica.

> **Stato del progetto:** questa documentazione è stata ricostruita analizzando l'intero archivio del progetto, inclusi modelli, servizi, viste, Network Extension, test, workflow CI e configurazione XcodeGen. Le funzionalità elencate distinguono deliberatamente tra ciò che è implementato nel codice e ciò che è soltanto rappresentato nei modelli/UI.

---

## Indice

- [Panoramica](#panoramica)
- [Caratteristiche principali](#caratteristiche-principali)
- [Live TV](#live-tv)
- [VOD e Film](#vod-e-film)
- [Serie TV ed Episodi](#serie-tv-ed-episodi)
- [EPG e Guida TV](#epg-e-guida-tv)
- [Catch-up / Replay](#catch-up--replay)
- [Player](#player)
- [Sorgenti e Playlist](#sorgenti-e-playlist)
- [Ricerca globale](#ricerca-globale)
- [Preferiti e gestione contenuti](#preferiti-e-gestione-contenuti)
- [Continua a guardare e cronologia](#continua-a-guardare-e-cronologia)
- [Metadata e arricchimento contenuti](#metadata-e-arricchimento-contenuti)
- [Trakt](#trakt)
- [Sottotitoli](#sottotitoli)
- [Download](#download)
- [VPN personale](#vpn-personale)
- [Parental Lock](#parental-lock)
- [iCloud Sync](#icloud-sync)
- [Tema e interfaccia](#tema-e-interfaccia)
- [Cache, catalogo e affidabilità di rete](#cache-catalogo-e-affidabilità-di-rete)
- [Diagnostica e Debug Mode](#diagnostica-e-debug-mode)
- [Backup e ripristino](#backup-e-ripristino)
- [Notifiche e promemoria EPG](#notifiche-e-promemoria-epg)
- [Architettura](#architettura)
- [Struttura del repository](#struttura-del-repository)
- [Modello dati](#modello-dati)
- [Tecnologie](#tecnologie)
- [Requisiti](#requisiti)
- [Configurazione e build](#configurazione-e-build)
- [CI/CD](#cicd)
- [Test](#test)
- [Sicurezza e gestione delle credenziali](#sicurezza-e-gestione-delle-credenziali)
- [Limiti e funzionalità non da confondere con quelle implementate](#limiti-e-funzionalità-non-da-confondere-con-quelle-implementate)
- [Verifica manuale](#verifica-manuale)
- [Contribuire](#contribuire)
- [Licenza](#licenza)
- [Disclaimer](#disclaimer)

---

## Panoramica

GassPlayer nasce come player IPTV nativo per iOS e si sviluppa attorno a quattro livelli principali:

```text
┌─────────────────────────────────────────────────────────────┐
│                         SwiftUI UI                          │
│ Home · Live TV · VOD · Serie · EPG · Search · Settings    │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                    Application Services                     │
│ Sources · Catalog · EPG · Search · History · Favorites     │
│ Downloads · Metadata · Trakt · Subtitles · VPN · Sync     │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                    Playback / Networking                     │
│ KSPlayer · Xtream API · M3U/M3U8 · URLSession · Network   │
│ Extension / WireGuardKit · iOS system integrations         │
└─────────────────────────────────────────────────────────────┘
```

Il progetto evita di trattare la playlist come un semplice elenco di URL: una sorgente diventa parte di un catalogo persistente, può essere verificata, rinominata, fissata, abilitata/disabilitata, esportata e, per le sorgenti Xtream, utilizzata per alimentare Live TV, VOD, Serie TV ed EPG.

---

# Caratteristiche principali

### Contenuti

- Live TV tramite Xtream Codes.
- Playlist M3U/M3U8.
- Cataloghi VOD.
- Film con schede dettaglio.
- Serie TV con stagioni ed episodi.
- EPG / Guida TV.
- Catch-up / replay quando supportato dalla sorgente.
- Preferiti separati per Live TV, VOD e Serie TV.
- Continua a guardare.
- Cronologia dei contenuti riprodotti.
- Ricerca globale.
- Ricerche recenti.

### Player

- Riproduzione video nativa tramite KSPlayer.
- Decodifica hardware/software configurabile.
- Picture in Picture.
- AirPlay audio/video.
- Selettore qualità.
- Selezione tracce audio e sottotitoli.
- Velocità di riproduzione.
- Seek e skip rapidi.
- Seek accurato configurabile.
- Buffer minimo/massimo.
- User-Agent personalizzato.
- Referer personalizzato.
- Header HTTP personalizzati.
- Cache HTTP.
- Filtri FFmpeg.
- Opzioni AVFormat/decoder/FFmpeg.
- De-interlacciamento.
- Decodifica asincrona.
- Modalità panorama/360°.
- Rapporto d'aspetto configurabile.
- Auto-rotate.
- Bitrate adattivo quando disponibile dal flusso/player.
- Loop.
- Sleep timer.
- Blocco controlli.
- Cronologia canali.
- Apertura con player esterni compatibili.

### Gestione

- Più sorgenti.
- Sorgente attiva.
- Pin delle sorgenti.
- Ordinamento.
- Abilitazione/disabilitazione.
- Rinomina.
- Duplica.
- Verifica connessione.
- Import/export JSON.
- Playlist unite.
- Cache catalogo.
- Aggiornamento manuale e automatico.
- Sync iCloud.
- Backup preferenze.
- Parental Lock.
- VPN personale.
- Debug e diagnostica.

---

# Live TV

La sezione Live TV utilizza principalmente le sorgenti **Xtream Codes** e presenta il catalogo in una griglia ottimizzata per la consultazione rapida.

## Funzioni

- Elenco dei canali.
- Categorie Xtream.
- Filtro "Tutti".
- Filtro "Senza categoria".
- Ricerca.
- Preferiti.
- Numerazione opzionale dei canali.
- Densità griglia configurabile.
- Riproduzione diretta.
- Informazioni EPG associate al canale quando disponibili.
- Programma attualmente in onda.
- Accesso al catch-up quando il provider lo espone.
- Aggregazione di più sorgenti Xtream.
- Selezione della sorgente attiva.
- Visualizzazione dei canali provenienti da più playlist.

Le chiamate Xtream vengono gestite tramite `XtreamAPIService` e, per il catalogo persistente/cacheato, tramite `CachedXtreamRepository` / `XtreamCatalogStore`.

## Aggregazione multi-sorgente

GassPlayer può caricare in parallelo le sorgenti Xtream abilitate e costruire gruppi di canali per sorgente.

Questo permette di mantenere separata la provenienza dei contenuti anche quando più playlist vengono utilizzate nella stessa installazione.

---

# VOD e Film

Le sorgenti Xtream possono fornire un catalogo VOD completo tramite gli endpoint standard del pannello.

## Catalogo

- Categorie film.
- Catalogo VOD globale.
- Recupero mirato delle categorie mancanti.
- Deduplicazione stabile degli stream.
- Cache persistente.
- Aggiornamento forzato.
- Aggiornamento automatico.
- Visualizzazione poster.
- Ricerca globale.
- Preferiti.

## Scheda film

La schermata dettaglio può includere:

- Titolo.
- Poster.
- Backdrop.
- Trama.
- Genere.
- Cast.
- Rating.
- Metadata arricchiti da servizi esterni.
- Rating Trakt quando configurato.
- Anteprima/trailer quando disponibile.
- Pulsante di riproduzione.
- Preferito.
- Download.

Il dettaglio parte dai dati forniti dal provider Xtream e può essere arricchito tramite TMDB e/o OMDb.

---

# Serie TV ed Episodi

GassPlayer supporta il catalogo Serie TV Xtream separatamente dal VOD.

## Serie

- Elenco serie.
- Categorie.
- Poster.
- Metadata.
- Ricerca.
- Preferiti.
- Scheda dettaglio.

## Stagioni

La schermata serie organizza gli episodi per stagione.

## Episodi

- Numero stagione.
- Numero episodio.
- Titolo.
- Metadata disponibili.
- Riproduzione diretta.
- Ripresa dal punto precedente.
- Download dell'episodio.
- Autoplay dell'episodio successivo.
- Preferiti a livello di serie.
- Indicazione del punto di ripresa.

L'impostazione **Precarica dettagli serie** può essere utilizzata per caricare in anticipo stagioni ed episodi mentre l'utente scorre il catalogo.

---

# EPG e Guida TV

La guida programmi è uno dei moduli più completi del progetto.

L'EPG è gestito da:

- `EPGService`
- `EPGManager`
- `EPGGridView`
- `EPGManageView`
- `EPGProgram`
- `EPGExternalSource`

## Fonti EPG

Le sorgenti Xtream possono fornire dati EPG tramite il provider.

È inoltre possibile registrare fonti XMLTV esterne HTTP/HTTPS.

Le fonti EPG esterne possono essere:

- aggiunte;
- modificate;
- rimosse;
- persistite;
- aggiornate.

## Guida

La guida supporta:

- visualizzazione per giorno;
- oggi;
- domani;
- ieri;
- griglia orizzontale;
- scheda programma;
- densità compatta/comoda;
- stile colore;
- layout configurabile;
- ricerca per nome programma;
- filtro preferiti;
- selezione gruppo playlist;
- tutti i canali;
- indicazione "In onda ora";
- indicazione dell'ora corrente;
- apertura diretta del canale;
- riproduzione live;
- riproduzione differita quando disponibile;
- promemoria;
- dettaglio programma.

## Aspetti EPG

Sono disponibili impostazioni per:

- densità della griglia;
- stile delle schede canale;
- stile colore delle celle;
- modalità dark/dinamica;
- numero di canali caricati progressivamente;
- preferiti EPG per sorgente.

Il caricamento della guida è progettato per evitare di renderizzare e richiedere simultaneamente tutto il catalogo quando non necessario.

---

# Catch-up / Replay

Quando il provider Xtream rende disponibile il replay per un canale e per un programma, GassPlayer può costruire l'URL di catch-up e proporre la riproduzione differita.

Nel dettaglio EPG possono comparire azioni come:

- Guarda in diretta.
- Riproduci differita.
- Imposta promemoria.
- Dettaglio programma.

La disponibilità effettiva dipende dal provider e dai dati EPG ricevuti.

---

# Player

Il player è costruito attorno a **KSPlayer** e a `KSPlaybackController`.

L'obiettivo è offrire un livello di controllo superiore a quello di un player video minimale, mantenendo comunque una UI utilizzabile su iPhone e iPad.

## Controlli di base

- Play/Pausa.
- Precedente.
- Successivo.
- Seek.
- Skip rapido.
- Timeline.
- Tempo corrente.
- Durata.
- Live indicator.
- Stato buffering.
- Retry dopo errore.
- Controlli a scomparsa automatica.
- Haptic feedback.

## Gesture

Il player implementa interazioni touch per:

- mostrare/nascondere i controlli;
- seek rapido con doppio tap;
- regolazioni contestuali;
- blocco dello schermo.

Il doppio tap sui lati della superficie video consente lo skip di circa 10 secondi avanti o indietro nei contenuti che espongono una durata seekable.

## Picture in Picture

Il player espone il supporto PiP quando disponibile e permette di avviare la modalità Picture in Picture dal controllo dedicato.

## AirPlay

Sono presenti controlli dedicati per:

- AirPlay audio;
- AirPlay video.

## Player esterni

GassPlayer riconosce diversi player esterni tramite URL scheme, tra cui:

- VLC.
- Infuse.
- Outplayer.

L'integrazione effettiva dipende dall'app esterna installata sul dispositivo.

> Chromecast è rappresentato nell'interfaccia come opzione futura/non integrata e richiede Google Cast SDK; non deve essere considerato una funzione Chromecast completa della build attuale.

---

# Impostazioni avanzate del player

`KSPlaybackController` espone un'ampia superficie di configurazione.

## Performance e decoding

- Decodifica hardware.
- Decodifica software/FFmpeg.
- VideoToolbox.
- Decompressione hardware asincrona.
- Decodifica video sincrona.
- Decodifica audio sincrona.
- Risoluzione FFmpeg:
  - piena;
  - metà;
  - un quarto.
- Low-resolution decoding.
- De-interlacciamento automatico.
- Apertura rapida / second open.
- Watchdog del player.

## Buffer

- Buffer minimo.
- Buffer massimo.
- Durata buffer preferita.
- Cache HTTP.
- Probesize.
- Durata massima analisi.

Queste impostazioni sono particolarmente utili con provider e stream che hanno latenze o comportamenti differenti.

## Seek

- Seek normale.
- Seek accurato.
- Flag di seek FFmpeg.
- Ripresa automatica dopo seek.
- Sincronizzazione video.
- Sincronizzazione audio/video.
- Delay video.

## Video

- Rapporto d'aspetto.
- Video gravity.
- Rotazione automatica.
- Video adattivo.
- Panorama / 360°.
- Loop.
- Disabilitazione video / modalità solo audio.

## Tracce

- Selezione traccia video.
- Selezione traccia audio.
- Selezione sottotitoli.
- Auto-select dei sottotitoli incorporati.
- Mantenimento dei sottotitoli immagine durante il seek.
- Supporto per testo, immagini e closed captions incorporati quando disponibili nel flusso.

## Header e rete

È possibile impostare:

- User-Agent.
- Referer.
- Header HTTP personalizzati.
- Opzioni AVFormatContext.
- Opzioni decoder.
- Opzioni FFmpeg generiche.
- Filtri video FFmpeg.
- Filtri audio FFmpeg.

Questo rende il player adattabile a sorgenti non uniformi e a flussi che richiedono header specifici.

---

# Sleep Timer

Il player include un timer di spegnimento.

L'utente può impostare una durata e, allo scadere:

1. la riproduzione viene messa in pausa;
2. il timer viene cancellato;
3. il player viene chiuso.

Il timer può essere annullato dal menu del player.

---

# Blocco controlli

Il player dispone di una modalità di blocco dello schermo.

Quando è attiva:

- i controlli vengono impediti;
- viene mostrato il controllo di sblocco;
- le interazioni accidentali durante la visione vengono ridotte.

---

# Sorgenti e Playlist

La gestione delle sorgenti è centralizzata in `SourceManager`.

## Tipi di sorgente rappresentati dal progetto

- Xtream Codes.
- M3U / M3U8.
- Plex.
- Jellyfin.
- Emby.

### Stato effettivo dell'implementazione

Nel codice analizzato, i backend di catalogo e riproduzione completi sono implementati per **Xtream Codes** e **M3U/M3U8**.

Plex, Jellyfin ed Emby sono presenti nel modello `MediaSourceType` e nell'interfaccia di selezione delle sorgenti, ma il repository analizzato non contiene servizi dedicati equivalenti a `XtreamAPIService` o `M3UPlaylistService` per quei tre backend. Per questo README non li presenta come integrazioni complete già disponibili.

## Gestione sorgenti

Ogni sorgente può avere:

- nome personalizzato;
- host/URL;
- username;
- password;
- API token dove previsto dal modello;
- stato abilitato/disabilitato;
- ordinamento;
- pin;
- icona personalizzata;
- timestamp ultima verifica;
- esito ultima verifica;
- numero di canali rilevati, quando disponibile.

## Sorgente attiva

L'utente può scegliere una sorgente attiva.

La sorgente attiva viene utilizzata dalle sezioni che lavorano sul catalogo principale.

## Pin

Le sorgenti possono essere fissate in alto per renderle più facilmente accessibili.

## Verifica

Le sorgenti Xtream possono essere verificate.

La verifica aggiorna:

- stato della connessione;
- data dell'ultima verifica;
- esito;
- conteggio canali quando disponibile.

È inoltre possibile verificare più sorgenti Xtream in una sola operazione.

## Duplica

Una sorgente può essere duplicata per creare rapidamente una configurazione derivata.

---

# M3U / M3U8

Il parser M3U è implementato in `M3UPlaylistService`.

Supporta:

- download della playlist;
- UTF-8;
- fallback ISO-8859-1;
- `#EXTINF`;
- titolo;
- `tvg-logo`;
- `group-title`;
- `tvg-id`;
- `tvg-type`;
- URL di stream.

## Classificazione automatica

Le playlist M3U non hanno uno standard universale per distinguere Live, Film e Serie.

GassPlayer applica una classificazione euristica con questo ordine:

1. `tvg-type`;
2. parole chiave in `group-title`;
3. pattern `SxxExx` nel titolo;
4. fallback su Live TV.

Questo consente di utilizzare playlist eterogenee senza richiedere un formato proprietario.

---

# Playlist unite

Il Content Management supporta la creazione di **playlist unite**.

Una playlist unita contiene più sorgenti e può essere:

- creata;
- rinominata;
- eliminata;
- riordinata.

Il sistema mantiene l'elenco degli ID delle sorgenti che la compongono.

---

# Ricerca globale

`GlobalSearchService` e `GlobalSearchView` implementano una ricerca trasversale sul catalogo.

La ricerca può coprire:

- Live TV;
- Film/VOD;
- Serie TV.

I risultati sono classificati per tipologia e possono essere filtrati.

## Ricerche recenti

Le query recenti vengono persistite tramite `SearchHistoryStore`.

Sono disponibili:

- visualizzazione delle ricerche recenti;
- rimozione singola;
- cancellazione della cronologia di ricerca.

---

# Preferiti e gestione contenuti

`ContentManagementService` centralizza i preferiti.

## Preferiti

Sono supportati:

- canali Live;
- film;
- serie.

Le sezioni Home possono mostrare separatamente:

- Preferiti Live TV;
- Preferiti VOD;
- Preferiti Serie TV.

## Gestione

È possibile:

- aggiungere;
- rimuovere;
- verificare se un contenuto è già preferito.

I dati vengono persistiti localmente.

---

# Continua a guardare e cronologia

`RecentlyWatchedStore` conserva gli elementi visualizzati di recente.

La Home può mostrare la sezione **Continua a guardare**.

Le impostazioni includono:

- ripresa della visione;
- cancellazione della cronologia;
- gestione degli elementi recenti.

Per le serie, il sistema può indicare stagione ed episodio da cui riprendere.

Il progetto include inoltre un meccanismo di sincronizzazione del progresso tramite iCloud.

---

# Metadata e arricchimento contenuti

GassPlayer separa i dati forniti dal provider dai metadata esterni.

## TMDB

`TMDBService` gestisce dati quali:

- ricerca;
- dettagli;
- generi;
- cast;
- immagini;
- backdrop;
- poster;
- identificativi esterni.

I poster possono essere arricchiti nella UI tramite `TMDBEnrichedPoster`.

## OMDb

`OMDbService` permette di utilizzare una API key configurabile per ottenere valutazioni e informazioni compatibili con OMDb.

## Metadata nella UI

La schermata impostazioni include una sezione dedicata a:

- TMDB;
- OMDb;
- configurazione delle API key;
- disponibilità dell'arricchimento.

Le integrazioni sono opzionali: il catalogo Xtream non dipende esclusivamente dai metadata esterni per poter essere riprodotto.

---

# Trakt

GassPlayer include un'integrazione con Trakt.

## Autenticazione

Il progetto utilizza il **Device Code OAuth flow**.

Il servizio gestisce:

- richiesta device code;
- codice utente;
- URL di verifica;
- polling del token;
- access token;
- refresh token.

## Rating

È possibile recuperare il rating pubblico di:

- film;
- serie.

Il lookup utilizza l'IMDb ID quando disponibile.

## Scrobbling

Durante la riproduzione sono disponibili chiamate Trakt per:

- scrobble start;
- scrobble stop;
- progresso di visione.

L'integrazione richiede un Client ID/secret Trakt configurato dall'utente e, per le funzioni account, un'autenticazione valida.

---

# Sottotitoli

Il progetto include `OpenSubtitlesService`.

È possibile cercare sottotitoli tramite OpenSubtitles usando:

- query;
- lingua;
- API key.

La lingua predefinita configurata dall'app è l'italiano, ma le impostazioni espongono anche:

- Italiano;
- English;
- Español;
- altri codici configurabili.

I sottotitoli incorporati nel flusso sono inoltre gestiti direttamente dal player quando disponibili.

---

# Download

Il progetto include un `DownloadManager` condiviso.

I download dei contenuti VOD/Serie vengono eseguiti tramite una `URLSession` in background.

## Funzioni

- avvio download;
- progresso per elemento;
- sessione background;
- persistenza delle attività;
- destinazione locale nel container documenti;
- gestione del completamento;
- apertura/condivisione tramite le API della UI che richiamano il download.

## Download solo Wi-Fi

È disponibile il toggle:

**Evita l'utilizzo della rete cellulare**

Quando attivo, la sessione di download viene configurata con `allowsCellularAccess = false`.

La preferenza è persistita in `UserDefaults`.

Se il valore cambia mentre sono presenti download attivi, la ricostruzione della sessione viene rimandata fino a quando non è sicuro applicare la nuova configurazione.

---

# VPN personale

GassPlayer include una Network Extension dedicata in:

```text
GassPlayer/PacketTunnel/
```

Il modulo principale utilizza:

- `NetworkExtension`;
- `NEVPNManager` per IKEv2;
- `NETunnelProviderManager` per il Packet Tunnel;
- `WireGuardKit` per il backend WireGuard presente nella build.

## Protocolli rappresentati

Il modello supporta:

- IKEv2;
- WireGuard;
- OpenVPN.

## IKEv2

IKEv2 viene configurato tramite le API native iOS:

- server address;
- remote identifier;
- username;
- password;
- configurazione `NEVPNProtocolIKEv2`.

Le credenziali sensibili vengono gestite tramite Keychain.

## WireGuard

Il Packet Tunnel contiene l'integrazione `WireGuardAdapter`.

La configurazione può includere:

- endpoint;
- chiave pubblica server;
- chiave privata client;
- pre-shared key;
- Allowed IPs;
- DNS;
- indirizzo client;
- MTU.

Le chiavi private e altre credenziali sensibili vengono conservate tramite Keychain e passate al tunnel tramite riferimenti, invece di essere mantenute come semplice stato UI.

## Watchdog

Il manager VPN osserva gli eventi `NEVPNStatusDidChange`.

Se il tunnel cade inaspettatamente mentre l'utente ne richiede la connessione, il watchdog pianifica tentativi di riconnessione con backoff progressivo fino a un numero massimo di tentativi.

## Auto connect / disconnect

Sono presenti impostazioni per:

- connessione automatica all'avvio;
- disconnessione quando l'app passa in background/uscita, secondo la configurazione scelta.

## OpenVPN

`VPNProtocolType` contiene anche `OpenVPN`, ma il `PacketTunnelProvider` analizzato implementa esplicitamente il percorso WireGuard; OpenVPN non deve essere considerato un backend crittografico completo della build corrente.

---

# Parental Lock

Il sistema di protezione è gestito da `ParentalLockManager`.

## Funzioni

- impostazione PIN;
- abilitazione/disabilitazione;
- verifica PIN;
- blocco categorie;
- sblocco categorie;
- persistenza dello stato.

Il PIN non viene memorizzato in chiaro: il manager calcola un hash SHA-256 prima della persistenza.

Il blocco è applicato a livello di categoria e può essere utilizzato per limitare l'accesso ai contenuti selezionati.

---

# iCloud Sync

`CloudSyncService` utilizza `NSUbiquitousKeyValueStore`.

Sono sincronizzabili:

- sorgenti;
- preferiti;
- progresso di visione.

Sono inoltre presenti notifiche per rilevare cambiamenti provenienti da un altro dispositivo.

La sincronizzazione è separata dal normale storage locale: l'app può continuare a funzionare localmente anche senza dati iCloud disponibili.

---

# Tema e interfaccia

L'app utilizza SwiftUI e un sistema di componenti chiamato internamente **Liquid Glass**.

Sono presenti componenti riutilizzabili per:

- pulsanti glass;
- card;
- righe impostazioni;
- liste;
- tab bar;
- sezioni;
- menu pill;
- icone delle sorgenti.

## Tema

`ThemeManager` gestisce il tema dell'app.

La UI supporta modalità coerenti con:

- chiaro;
- scuro;
- dinamico.

Il progetto include fallback a materiali SwiftUI come `.ultraThinMaterial` per gli ambienti in cui le API di vetro più recenti non sono disponibili.

## Responsive UI

Il progetto è pensato per iPhone e iPad e usa SwiftUI per adattare:

- griglie;
- navigazione;
- pannelli;
- player;
- impostazioni;
- EPG.

---

# Cache, catalogo e affidabilità di rete

La rete non viene gestita esclusivamente dalla UI.

## Cache

Sono presenti servizi distinti per:

- catalogo Xtream;
- EPG;
- metadata;
- dati temporanei;
- snapshot persistenti.

`PersistentCatalogStore` permette di conservare snapshot del catalogo.

## Retry

`RetryPolicy` implementa una strategia di retry con backoff.

È utilizzata dai livelli di servizio che necessitano di resilienza alle chiamate di rete.

## Aggiornamento catalogo

`CatalogSettings` permette di configurare l'aggiornamento.

Le opzioni includono:

- aggiornamento automatico;
- aggiornamento all'avvio;
- aggiornamento manuale;
- refresh forzato;
- svuotamento cache catalogo.

## Ottimizzazione Xtream

`XtreamAPIService.fetchAllStreams` evita di richiedere inutilmente ogni categoria quando la risposta globale del provider contiene già gli stream.

Il comportamento è:

1. richiesta globale degli stream;
2. recupero categorie quando necessario;
3. identificazione delle categorie realmente assenti;
4. richieste mirate solo per le categorie mancanti;
5. recupero concorrente a batch;
6. deduplicazione stabile.

Questo riduce drasticamente il numero di richieste HTTP su provider con molte categorie.

---

# Diagnostica e Debug Mode

Il progetto include un sistema di logging centralizzato:

- `DebugLogger`;
- `DebugLogEntry`;
- `DebugConsoleView`.

Sono disponibili strumenti per osservare eventi tecnici e problemi di rete.

## Diagnostica ATS

`ATSDiagnosticView` consente di verificare aspetti relativi a:

- App Transport Security;
- raggiungibilità;
- configurazione di rete.

Questo è particolarmente utile quando una playlist o un provider utilizza host con configurazioni TLS/HTTP non standard.

## Network monitor

Il progetto contiene componenti per monitorare lo stato della rete e gestire comportamenti dipendenti dalla connettività.

---

# Backup e ripristino

GassPlayer distingue tra backup delle sorgenti e backup delle preferenze.

## Backup sorgenti

È possibile esportare le sorgenti configurate in JSON.

Il backup può essere:

- copiato;
- condiviso;
- reimportato.

Durante l'importazione vengono ignorate le sorgenti già presenti secondo il confronto host + username.

## Backup preferenze

`AppPreferencesBackupCodec` può serializzare preferenze come:

- tema;
- catalogo;
- EPG;
- download;
- riproduzione;
- griglia;
- altre impostazioni applicative supportate.

Il backup delle preferenze può essere copiato negli appunti e reimportato.

---

# Notifiche e promemoria EPG

`ReminderService` utilizza `UserNotifications`.

Per un programma EPG è possibile:

- richiedere l'autorizzazione alle notifiche;
- impostare un promemoria;
- ricevere una notifica prima dell'inizio;
- cancellare il promemoria.

Il comportamento predefinito del servizio è un promemoria **5 minuti prima** dell'inizio del programma.

---

# Home

La Home aggrega i principali ingressi dell'app:

- panoramica;
- Live TV;
- Preferiti Live TV;
- VOD;
- Preferiti VOD;
- Serie TV;
- Preferiti Serie;
- Continua a guardare;
- Guida TV;
- sorgenti.

Quando non esistono sorgenti configurate, la Home fornisce un percorso diretto per aggiungerne una.

---

# Impostazioni

La schermata Impostazioni è organizzata per aree funzionali.

## Connessioni

- Sorgenti.
- EPG.
- Sorgente attiva.
- VPN personale.

## Riproduzione

- Autoplay episodio successivo.
- Ripresa della visione.
- Velocità predefinita.
- Ripristino impostazioni player.

## Aspetto

- Tema.
- Densità griglia.
- Numerazione canali.

## Libreria

- Preferenze lingua sottotitoli.
- Organizzazione catalogo.

## Catalogo

- Aggiornamento automatico.
- Aggiornamento all'avvio.
- Programma live nelle celle.
- Precaricamento dettagli serie.
- Aggiornamento immediato.
- Svuotamento cache.

## Cronologia

- Continua a guardare.
- Elementi recenti.
- Svuotamento cronologia.

## Metadata

- TMDB.
- OMDb.
- API key.

## Servizi

- iCloud.
- Download solo Wi-Fi.
- DNS preferito.
- Trakt.

## Sicurezza

- Parental Lock.

## Diagnostica

- Debug e log.
- Diagnostica rete.
- Cache di sistema.

## Dati

- Backup sorgenti.
- Backup preferenze.
- Importazione preferenze.
- Ripristino impostazioni.

---

# Architettura

La struttura applicativa segue un'organizzazione per responsabilità.

```text
GassPlayer/
├── App/
│   └── GassPlayerApp.swift
│
├── Models/
│   ├── CatchupModels.swift
│   ├── ContentManagementModels.swift
│   ├── DebugLogEntry.swift
│   ├── EPGExternalSource.swift
│   ├── EPGProgram.swift
│   ├── M3UModels.swift
│   ├── MediaDetail.swift
│   ├── MediaSource.swift
│   ├── ParentalLock.swift
│   ├── PersonalVPNConfig.swift
│   ├── VPNConfig.swift
│   ├── XtreamModels.swift
│   ├── XtreamSeriesModels.swift
│   └── XtreamVODModels.swift
│
├── PacketTunnel/
│   ├── PacketTunnelProvider.swift
│   ├── TunnelKeychainHelper.swift
│   ├── Info.plist
│   └── PacketTunnel.entitlements
│
├── Resources/
│   ├── Assets.xcassets/
│   ├── Info.plist
│   ├── GassPlayer.entitlements
│   └── GassPlayer-CI.entitlements
│
├── Services/
│   ├── AggregatedSourceService.swift
│   ├── AppPreferencesBackupCodec.swift
│   ├── CacheService.swift
│   ├── CatalogSettings.swift
│   ├── CloudSyncService.swift
│   ├── ContentManagementService.swift
│   ├── DebugLogger.swift
│   ├── DownloadManager.swift
│   ├── EPGManager.swift
│   ├── EPGService.swift
│   ├── FlexibleDecoding.swift
│   ├── GlobalSearchService.swift
│   ├── KSPlaybackController.swift
│   ├── M3UPlaylistService.swift
│   ├── M3UPlaylistStore.swift
│   ├── NavigationOverlayState.swift
│   ├── NetworkMonitor.swift
│   ├── OMDbService.swift
│   ├── OpenSubtitlesService.swift
│   ├── ParentalLockManager.swift
│   ├── PersistentCatalogStore.swift
│   ├── PersonalVPNManager.swift
│   ├── RecentlyWatchedStore.swift
│   ├── ReminderService.swift
│   ├── RetryPolicy.swift
│   ├── SearchHistoryStore.swift
│   ├── SourceBackupCodec.swift
│   ├── SourceManager.swift
│   ├── SourceVerificationService.swift
│   ├── TMDBService.swift
│   ├── ThemeManager.swift
│   ├── TraktAccountManager.swift
│   ├── TraktService.swift
│   ├── XtreamAPIService.swift
│   └── XtreamCatalogStore.swift
│
└── Views/
    ├── ATSDiagnosticView.swift
    ├── AdaptivePlayerView.swift
    ├── AllSourcesLiveView.swift
    ├── AlternateSourcesView.swift
    ├── BufferSettingsView.swift
    ├── ChannelGridView.swift
    ├── ChannelsView.swift
    ├── ContentView.swift
    ├── DebugConsoleView.swift
    ├── EPGGridView.swift
    ├── EPGManageView.swift
    ├── GlobalSearchView.swift
    ├── GlobalToolbarButtons.swift
    ├── HomeView.swift
    ├── LiquidGlass/
    ├── LoginView.swift
    ├── M3UChannelsView.swift
    ├── MediaDetailComponents.swift
    ├── MetadataSettingsView.swift
    ├── MovieDetailView.swift
    ├── ParentalLockView.swift
    ├── PersonalVPNView.swift
    ├── PlayerView.swift
    ├── SeriesEpisodesView.swift
    ├── SettingsView.swift
    ├── SourceManageView.swift
    ├── SourceManagerView.swift
    ├── SourcesView.swift
    ├── SplashScreenView.swift
    ├── TMDBEnrichedPoster.swift
    └── TraktConnectView.swift
```

---

# Modello dati

## `MediaSourceConfig`

Rappresenta una sorgente configurata dall'utente.

Contiene:

- identificativo;
- nome;
- tipo;
- host;
- credenziali;
- token;
- stato;
- ordine;
- pin;
- verifica;
- conteggio canali;
- icona.

## `XtreamCredentials`

Rappresenta le credenziali necessarie per il client Xtream.

## `XtreamStream`

Rappresenta un elemento Live o VOD.

## `XtreamSeriesItem`

Rappresenta una serie nel catalogo.

## `XtreamSeriesInfo`

Contiene dettagli, stagioni ed episodi di una serie.

## `EPGProgram`

Rappresenta un programma televisivo con:

- ID;
- titolo;
- orario;
- durata/intervallo;
- informazioni di replay quando disponibili.

## `FavoriteItem`

Rappresenta un elemento preferito.

## `RecentlyWatchedItem`

Rappresenta un elemento nella cronologia/Continua a guardare.

## `PersonalVPNConfig`

Rappresenta una configurazione VPN personale.

---

# Tecnologie

| Area | Tecnologia |
|---|---|
| Linguaggio | Swift 5.10 |
| UI | SwiftUI |
| Target | iOS 17.0+ |
| Dispositivi | iPhone + iPad |
| Player | KSPlayer |
| Rendering video | AVFoundation / backend KSPlayer / FFmpeg secondo configurazione |
| IPTV API | Xtream Codes |
| Playlist | M3U / M3U8 |
| EPG | Xtream + XMLTV esterno |
| Metadata | TMDB + OMDb |
| Tracking | Trakt |
| Sottotitoli | OpenSubtitles |
| Download | URLSession background |
| Sync | NSUbiquitousKeyValueStore |
| VPN | NetworkExtension + WireGuardKit + IKEv2 nativo |
| Sicurezza credenziali | Keychain |
| Logging | DebugLogger |
| Build project | XcodeGen |
| Lint | SwiftLint |
| CI | GitHub Actions |
| Test | XCTest |

---

# Requisiti

- macOS con Xcode.
- SDK iOS compatibile con il deployment target iOS 17.
- XcodeGen.
- SwiftLint.
- Account Apple Developer per installazione e firma su dispositivo fisico.
- Un dispositivo o simulatore iOS/iPadOS 17+.

Il progetto utilizza:

```text
IPHONEOS_DEPLOYMENT_TARGET = 17.0
SWIFT_VERSION = 5.10
TARGETED_DEVICE_FAMILY = 1,2
```

---

# Configurazione locale

Il progetto usa **XcodeGen**.

Installazione tipica degli strumenti:

```bash
brew install xcodegen swiftlint
```

Generazione del progetto:

```bash
xcodegen generate
```

Apertura:

```bash
open GassPlayer.xcodeproj
```

Se il repository include il `Makefile`, sono disponibili anche scorciatoie come:

```bash
make open
make verify
```

Il `Makefile` è una comodità e non costituisce una dipendenza architetturale dell'app.

---

# Build

Dopo la generazione del progetto:

```bash
xcodebuild \
  -project GassPlayer.xcodeproj \
  -scheme GassPlayer \
  -configuration Debug \
  build
```

Per un dispositivo reale è necessario configurare la firma Apple appropriata.

Il progetto è configurato per una build CI senza firma quando non sono disponibili certificati/provisioning.

---

# CI/CD

Il workflow GitHub Actions è definito in:

```text
.github/workflows/build.yml
```

La pipeline comprende:

```text
Repository
   │
   ├── controllo duplicati
   │
   ├── SwiftLint
   │
   ├── XCTest
   │
   └── xcodebuild / archive
             │
             └── IPA firmato o non firmato
```

## Lint

SwiftLint viene eseguito automaticamente.

Le violazioni configurate possono interrompere la pipeline.

## Test

La suite `GassPlayerTests` viene eseguita prima della fase di build.

## Build

La fase finale genera l'artefatto dell'app secondo la disponibilità della firma.

La build CI è predisposta anche per produrre un IPA non firmato quando non vengono forniti i segreti di code signing.

---

# Test

La suite di test analizzata include:

```text
GassPlayerTests/
├── M3UPlaylistServiceTests.swift
├── MediaSourceConfigTests.swift
├── ParentalLockManagerTests.swift
├── RetryPolicyTests.swift
├── SearchHistoryStoreTests.swift
├── SourceBackupCodecTests.swift
└── XtreamAPIServiceTests.swift
```

## Aree testate

### M3U

- parsing;
- classificazione;
- attributi.

### Media sources

- codifica/decodifica;
- compatibilità del modello;
- persistenza dei campi.

### Parental Lock

- PIN;
- stato;
- blocco/sblocco.

### Retry

- backoff;
- condizioni di retry;
- gestione errori.

### Search history

- inserimento;
- rimozione;
- persistenza.

### Backup

- serializzazione;
- deserializzazione;
- round-trip dei dati.

### Xtream

- costruzione endpoint;
- URL;
- decoding;
- credenziali;
- comportamento del client.

---

# Sicurezza e gestione delle credenziali

GassPlayer tratta credenziali e configurazioni sensibili con livelli differenti.

## Keychain

Le credenziali VPN sensibili possono essere salvate tramite Keychain, inclusi:

- password IKEv2;
- password tunnel;
- pre-shared key;
- private key WireGuard.

## UserDefaults

Vengono usati per preferenze applicative non sensibili e piccoli snapshot, ad esempio:

- tema;
- preferenze player;
- griglia;
- cronologia di ricerca;
- preferenze download;
- stato parental lock;
- metadati non segreti.

## Privacy

GassPlayer non fornisce un servizio IPTV proprietario e non contiene un catalogo televisivo centralizzato.

L'utente deve configurare le proprie sorgenti e i propri servizi.

---

# Limiti e funzionalità non da confondere con quelle implementate

Questa sezione è volutamente esplicita per evitare che il README trasformi modelli o placeholder UI in funzionalità dichiarate come complete.

## Plex / Jellyfin / Emby

I tipi di sorgente:

- Plex;
- Jellyfin;
- Emby

sono presenti nel modello e nell'interfaccia di aggiunta sorgente.

Nel codice analizzato non risultano però implementati backend di catalogo/riproduzione dedicati paragonabili a Xtream e M3U.

Pertanto la build deve essere considerata principalmente una piattaforma:

- Xtream Codes;
- M3U/M3U8.

## OpenVPN

`OpenVPN` è presente nell'enum dei protocolli VPN e nella UI/configurazione.

Il Packet Tunnel analizzato implementa il percorso WireGuard; IKEv2 usa il protocollo nativo iOS.

OpenVPN non deve essere documentato come backend crittografico completo della build attuale.

## Chromecast

La UI riconosce la possibilità futura di Chromecast, ma non è presente una vera integrazione Google Cast SDK nel progetto analizzato.

## VPN provider-derived

Il README precedente faceva riferimento a un meccanismo di recupero della VPN dal provider Xtream.

Nel codice analizzato non è stata trovata una funzione attiva `fetchProviderVPNConfig()` né un backend equivalente da documentare come feature corrente.

La VPN va quindi considerata come **VPN personale configurabile manualmente**.

## Sorgenti M3U

M3U è supportato come playlist e può essere classificato euristicamente in Live/VOD/Serie.

La semantica esatta dipende dai metadata presenti nella playlist.

## Catch-up

Il catch-up non è garantito da ogni provider.

La disponibilità dipende dai dati EPG e dal supporto replay esposto dal server.

## Metadata

TMDB, OMDb, Trakt e OpenSubtitles sono integrazioni opzionali e richiedono le rispettive configurazioni/API quando necessarie.

---

# Verifica manuale

Prima di distribuire una build, verificare almeno:

## Sorgenti

- Aggiunta sorgente Xtream.
- Aggiunta playlist M3U.
- Rinomina.
- Pin.
- Ordinamento.
- Abilitazione/disabilitazione.
- Duplica.
- Eliminazione.
- Verifica connessione.
- Import/export JSON.
- Selezione sorgente attiva.

## Live TV

- Caricamento categorie.
- Caricamento canali.
- Ricerca.
- Preferiti.
- Riproduzione.
- Cambio sorgente.
- Aggregazione multi-sorgente.
- Numerazione canali.
- Densità griglia.

## VOD

- Caricamento categorie.
- Ricerca.
- Poster.
- Dettaglio.
- Riproduzione.
- Preferiti.
- Metadata.
- Download.

## Serie

- Caricamento serie.
- Stagioni.
- Episodi.
- Ripresa.
- Autoplay.
- Preferiti.
- Download episodio.

## EPG

- Caricamento guida.
- Giorni.
- Ricerca.
- Gruppi.
- Preferiti.
- Programma corrente.
- Live.
- Catch-up.
- Promemoria.
- Fonti XMLTV esterne.

## Player

- Play/Pausa.
- Seek.
- Skip.
- Buffer.
- Qualità.
- Audio.
- Sottotitoli.
- Velocità.
- PiP.
- AirPlay.
- Sleep timer.
- Lock.
- Player esterno.
- Impostazioni FFmpeg.
- Retry.

## Download

- Download Wi-Fi.
- Progresso.
- Completamento.
- File locale.
- Riavvio app.
- Condivisione/apertura dove previsto dalla UI.

## VPN

- Profilo IKEv2.
- Profilo WireGuard.
- Keychain.
- Connect/disconnect.
- Riconnessione watchdog.
- Auto connect.
- Auto disconnect.
- Rimozione profilo.

## Sicurezza

- Parental Lock.
- PIN.
- Blocco categoria.
- Sblocco.
- Persistenza dopo relaunch.

## Sync

- Push sorgenti.
- Pull sorgenti.
- Push preferiti.
- Push progresso.
- Modifica esterna iCloud.

## Diagnostica

- Debug console.
- ATS diagnostics.
- Log.
- Svuotamento cache.

---

# Contribuire

Le contribuzioni sono benvenute, in particolare per:

- stabilità del player;
- compatibilità con provider Xtream differenti;
- parser M3U;
- EPG;
- prestazioni catalogo;
- accessibilità;
- UI SwiftUI;
- integrazione metadata;
- gestione rete;
- test;
- documentazione.

## Workflow consigliato

```bash
git checkout -b feature/nome-della-feature
```

Apportare modifiche mantenendo:

- separazione Models / Services / Views;
- stato centralizzato dove appropriato;
- compatibilità con iOS 17+;
- Swift concurrency corretta;
- assenza di polling non necessario;
- test delle funzionalità di rete;
- comportamento coerente tra sorgenti e modalità.

Prima di aprire una Pull Request:

```bash
swiftlint
```

e:

```bash
xcodebuild test \
  -project GassPlayer.xcodeproj \
  -scheme GassPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

# Struttura delle responsabilità

Una delle regole architetturali più importanti del progetto è evitare di duplicare la logica tra viste.

```text
SwiftUI Views
     │
     ▼
Observable Managers / Stores
     │
     ├── SourceManager
     ├── ContentManagementService
     ├── RecentlyWatchedStore
     ├── EPGManager
     ├── CatalogSettings
     ├── ParentalLockManager
     └── ThemeManager
     │
     ▼
Actors / Services
     │
     ├── XtreamAPIService
     ├── M3UPlaylistService
     ├── EPGService
     ├── TMDBService
     ├── OMDbService
     ├── TraktService
     ├── OpenSubtitlesService
     ├── DownloadManager
     └── PersistentCatalogStore
```

L'uso di `actor` per diversi servizi di rete riduce il rischio di accessi concorrenti non controllati e si integra con Swift Concurrency.

---

# Filosofia progettuale

## Native first

Quando una funzione è disponibile tramite API iOS supportate, GassPlayer privilegia l'integrazione nativa.

Esempi:

- NetworkExtension;
- Keychain;
- UserNotifications;
- iCloud Key-Value Store;
- URLSession;
- Picture in Picture;
- AirPlay;
- SwiftUI.

## Provider agnostic

Xtream e M3U possono avere risposte molto diverse.

Il codice utilizza quindi:

- decoding flessibile;
- retry;
- normalizzazione URL;
- deduplicazione;
- cache;
- fallback;
- richieste mirate.

## Performance

Il catalogo non deve essere ricaricato inutilmente.

Per questo:

- le richieste possono essere cacheate;
- le categorie mancanti vengono recuperate solo quando necessario;
- le richieste indipendenti possono essere eseguite in parallelo;
- i risultati vengono deduplicati;
- il rendering UI è separato dalla rete.

## Trasparenza

Quando una funzionalità è solo parzialmente supportata dal backend, l'app e la documentazione dovrebbero dichiararlo invece di presentarla come completa.

---

# Licenza

Il progetto include una licenza:

**MIT License**

Copyright (c) 2026 iamgasgass

La licenza consente, secondo i termini MIT:

- uso;
- copia;
- modifica;
- fusione;
- pubblicazione;
- distribuzione;
- sublicenza;
- vendita di copie del software.

La licenza completa è disponibile nel file:

```text
LICENSE
```

---

# Disclaimer

GassPlayer è un'applicazione indipendente per la riproduzione di contenuti forniti dall'utente.

Il progetto:

- non fornisce liste IPTV proprietarie;
- non distribuisce credenziali IPTV;
- non garantisce la disponibilità o legalità delle sorgenti configurate dall'utente;
- non controlla i contenuti serviti dai provider;
- non è affiliato ai provider IPTV utilizzati dall'utente;
- non è affiliato ai servizi esterni integrati.

L'utente è responsabile dell'utilizzo delle sorgenti, delle credenziali, dei servizi esterni e dei contenuti a cui accede.

Le integrazioni con TMDB, OMDb, Trakt, OpenSubtitles, WireGuardKit e altri progetti di terze parti sono soggette ai rispettivi termini e licenze.

---

# Riepilogo funzionale

| Area | Stato nel progetto analizzato |
|---|---|
| SwiftUI app | Implementato |
| iOS 17+ | Implementato/configurato |
| iPhone + iPad | Configurato |
| Xtream Codes | Implementato |
| M3U/M3U8 | Implementato |
| Live TV | Implementato |
| VOD | Implementato |
| Serie TV | Implementato |
| EPG Xtream | Implementato |
| XMLTV esterno | Implementato |
| Catch-up | Implementato quando supportato dal provider |
| Multi-source Xtream | Implementato |
| Playlist unite | Implementato |
| Preferiti | Implementato |
| Continua a guardare | Implementato |
| Cronologia ricerca | Implementato |
| Ricerca globale | Implementato |
| TMDB | Integrato/opzionale |
| OMDb | Integrato/opzionale |
| Trakt | Integrato/opzionale |
| OpenSubtitles | Integrato/opzionale |
| Download | Implementato |
| Download solo Wi-Fi | Implementato |
| PiP | Implementato |
| AirPlay | Implementato |
| Player esterni | Implementato |
| Chromecast | Non integrato |
| IKEv2 | Integrato tramite iOS |
| WireGuard | Integrato tramite Packet Tunnel/WireGuardKit |
| OpenVPN | Modello/UI presenti, backend completo non documentabile come attivo |
| Parental Lock | Implementato |
| iCloud sync | Implementato |
| Backup JSON sorgenti | Implementato |
| Backup preferenze | Implementato |
| Debug console | Implementato |
| ATS diagnostics | Implementato |
| SwiftLint | Integrato |
| XCTest | Integrato |
| GitHub Actions | Integrato |
| Plex | Tipo sorgente presente, backend dedicato non implementato |
| Jellyfin | Tipo sorgente presente, backend dedicato non implementato |
| Emby | Tipo sorgente presente, backend dedicato non implementato |

---

## GassPlayer

Un player IPTV nativo per iOS che unisce **Live TV, VOD, Serie TV, EPG, catch-up, metadata, multi-source, player avanzato, download, VPN e strumenti di gestione** in una singola app SwiftUI.

Costruito per essere veloce, configurabile e trasparente su ciò che il provider supporta realmente.

