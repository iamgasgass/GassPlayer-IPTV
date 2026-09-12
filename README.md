# GassPlayer IPTV

App iOS originale per streaming IPTV (Xtream Codes + M3U/M3U8), VPN derivata
dal server del provider, interfaccia Liquid Glass (iOS 26, con fallback
`.ultraThinMaterial` per SDK precedenti). Bundle id: `com.iamgasgass.gassPlayer`.

## Struttura repo

```
GassPlayerIPTV/
├── project.yml                 # Manifest XcodeGen: genera 3 target
│                                 (GassPlayer, PacketTunnel, GassPlayerTests)
├── Makefile                    # Scorciatoie locali (opzionale, vedi sotto)
├── .swiftlint.yml               # Regole di stile del codice
├── GassPlayer/                 # App principale (Models/Services/Views/App/Resources)
│   └── PacketTunnel/            # Network Extension per il tunnel VPN
├── GassPlayerTests/             # Test unitari
└── .github/workflows/build.yml # CI: lint -> test -> build -> IPA
```

## Setup locale

```bash
brew install xcodegen swiftlint
make open        # genera il progetto e apre Xcode
make verify       # controlla che non ci siano file .swift duplicati
```

Il `Makefile` è solo una comodità per i comandi da terminale: puoi
eliminarlo senza conseguenze, la CI non lo usa (chiama `xcodegen`/`xcodebuild`
direttamente).

## VPN — cosa è reale e cosa resta da completare

`GassPlayer/PacketTunnel/PacketTunnelProvider.swift` è ora un target
Network Extension **reale** (prima la VPN puntava a un bundle id senza che
il target esistesse — impossibile che si connettesse). Gestisce
correttamente il lifecycle del tunnel e le network settings (IP virtuale,
DNS, rotte). **Non contiene crittografia VPN reale**: quella richiede una
libreria auditata come [WireGuardKit](https://github.com/WireGuard/wireguard-apple),
da aggiungere come dipendenza SPM al target `PacketTunnel`. Scrivere un
protocollo crittografico da zero senza audit di sicurezza sarebbe
irresponsabile, quindi quella parte resta un TODO esplicito nel codice.

## Test

```bash
xcodebuild test -project GassPlayer.xcodeproj -scheme GassPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Copertura attuale: parser M3U, retry policy con backoff, costruzione URL
Xtream Codes, round-trip Codable dei modelli, parental lock manager.

## CI (`.github/workflows/build.yml`)

Tre fasi in sequenza: **lint** (SwiftLint, fallisce la build su violazioni),
**test** (xcodebuild test, log sempre caricato come artifact), **build**
(archive firmato se configuri i secrets di firma, altrimenti IPA non
firmato). Controllo automatico anti-duplicati come primo step.

## Limiti onesti (non bug, scelte esplicite)

- Il protocollo VPN reale (crittografia) non è incluso: vedi sopra.
- `fetchProviderVPNConfig()` prova endpoint comuni tra pannelli Xtream con
  VPN abbinata, non uno standard ufficiale — se il tuo provider usa un
  endpoint diverso, aggiungilo in `Services/XtreamAPIService.swift`.
- Nessun sistema di acquisti in-app: tutte le funzionalità sono attive di
  default per scelta esplicita, non per limite tecnico.
