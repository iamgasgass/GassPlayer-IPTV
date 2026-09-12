# Contribuire a GassPlayer IPTV

## Setup ambiente di sviluppo

```bash
brew install xcodegen swiftlint
git clone https://github.com/iamgasgass/GassPlayer-IPTV.git
cd GassPlayer-IPTV
make open
```

## Prima di ogni commit

```bash
make verify     # controlla che non ci siano file .swift duplicati
swiftlint       # controlla lo stile del codice
```

## Convenzioni

- **Naming**: `PascalCase` per tipi/struct/enum, `camelCase` per proprietà/metodi.
- **Un tipo pubblico principale per file**: evita di definire più `struct`/`class` non correlati nello stesso file, per prevenire i problemi di redeclaration già avuti in passato.
- **Concorrenza**: il progetto usa Swift 6 strict concurrency. Ogni tipo che tocca UI deve essere `@MainActor`; le chiusure di `NotificationCenter`/completion handler di API di sistema non sono isolate di default — usa `Task { @MainActor in ... }` per rientrare in sicurezza.
- **Errori**: usa i case esistenti di `XtreamError` (`Models/XtreamModels.swift`) invece di crearne di nuovi sparsi; se serve un nuovo case, aggiungilo lì e aggiorna anche `errorDescription`.

## Pull request

1. Crea un branch da `main`: `feature/nome-breve` o `fix/nome-breve`.
2. Esegui `make verify` e i test (`Cmd+U` in Xcode, o `xcodebuild test` con lo schema `GassPlayer`).
3. Descrivi nella PR cosa cambia e perché, non solo il "cosa".

## Aree che richiedono attenzione extra

- **PacketTunnelProvider.swift**: contiene solo lo scheletro del tunnel VPN, senza crittografia reale. Se lavori su questa parte, integra una libreria auditata (es. WireGuardKit) invece di scrivere primitive crittografiche da zero.
- **XtreamAPIService.fetchProviderVPNConfig()**: gli endpoint tentati sono ipotesi basate su pannelli comuni, non uno standard ufficiale Xtream Codes. Se il tuo provider usa un endpoint diverso, aggiungilo alla lista `candidateActions`/`candidatePaths`.
