# GassPlayer IPTV

Bundle id: com.iamgasgass.gassPlayer

Repo sovrascritta interamente via API GitHub per eliminare l'inconsistenza
tra patch precedenti. GassPlayer/Views/BufferSettingsView.swift e
GassPlayer/Services/NetworkMonitor.swift sono stati neutralizzati (contenuto
vuoto) perche' duplicavano/non facevano parte dell'architettura corrente:
BufferSettingsView, QualityPickerView e TrackPickerView sono definite UNA
sola volta, dentro GassPlayer/Views/PlayerView.swift.

## Setup

    brew install xcodegen
    make open
    make build
    make ipa
