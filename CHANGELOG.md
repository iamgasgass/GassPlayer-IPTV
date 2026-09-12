# Changelog

Tutte le modifiche rilevanti al progetto sono documentate qui.
Formato basato su [Keep a Changelog](https://keepachangelog.com/it/1.0.0/).

## [Unreleased]

### Aggiunto
- Target Network Extension (`PacketTunnelProvider`) — scheletro reale per il tunnel VPN, con TODO esplicito sull'integrazione WireGuardKit necessaria per la crittografia.
- Suite di test unitari (`GassPlayerTests`): parser M3U, retry policy, costruzione URL Xtream, codable dei modelli, parental lock.
- `.swiftlint.yml` e step di lint nel workflow CI.
- `LICENSE` (MIT), `CONTRIBUTING.md`, template issue GitHub.

### Corretto
- Rimossi file duplicati/orfani (`BufferSettingsView.swift` standalone, riferimenti a `NetworkMonitor` in `ChannelsView.swift`) che causavano `invalid redeclaration` e `cannot find in scope` in CI.
- Risolti tutti gli errori di Swift 6 strict concurrency (nonisolated su `streamURL`, hop espliciti a `@MainActor` nelle closure di `NotificationCenter`, `XtreamError` unificato in un'unica definizione).

## [0.1.0] - 2026-09-12

### Aggiunto
- Struttura iniziale del progetto: multi-sorgente Xtream Codes/M3U, EPG con catch-up, player con PiP reale/gesture volume-luminosità/selettore qualità, griglia canali, content management (rename/reorder/merge/favourite), VPN derivata dal server del provider, tema chiaro/scuro, cache+retry per le chiamate di rete, sync iCloud, Debug Mode.
