# GassPlayer IPTV

Bundle id: com.iamgasgass.gassPlayer

Repo sovrascritta interamente via API GitHub per eliminare l'inconsistenza
tra patch precedenti. GassPlayer/Views/BufferSettingsView.swift e
GassPlayer/Services/NetworkMonitor.swift sono stati neutralizzati (contenuto
vuoto) perche' duplicavano/non facevano parte dell'architettura corrente:
BufferSettingsView, QualityPickerView e TrackPickerView sono definite UNA
sola volta, dentro GassPlayer/Views/PlayerView.swift. ChannelsView.swift
non referenzia piu' NetworkMonitor.

## Setup

    brew install xcodegen
    make open
    make build
    make ipa

## Se la build fallisce ancora

Esegui `make verify` in locale: cerca automaticamente nomi di file .swift
duplicati in punti diversi della cartella GassPlayer/. Lo stesso controllo
e' il primo step del workflow CI.
