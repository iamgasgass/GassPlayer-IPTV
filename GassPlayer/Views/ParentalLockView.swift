import SwiftUI

struct ParentalLockView: View {
    @EnvironmentObject var lockManager: ParentalLockManager
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Protezione PIN") {
                    Toggle("Attiva parental lock", isOn: Binding(
                        get: { lockManager.state.isEnabled },
                        set: { enabled in enabled ? lockManager.setPIN(pin) : lockManager.disable() }
                    ))
                    if !lockManager.state.isEnabled {
                        SecureField("Imposta PIN a 4 cifre", text: $pin).keyboardType(.numberPad)
                    }
                }
                Section("Categorie bloccate") {
                    Text("\(lockManager.state.lockedCategoryIds.count) categorie protette").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Parental Lock")
        }
    }
}
