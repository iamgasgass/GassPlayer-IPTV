import SwiftUI

struct ATSDiagnosticView: View {
    var body: some View {
        List {
            Section {
                diagnosticRow(
                    label: "NSAllowsArbitraryLoads",
                    value: allowsArbitraryLoads,
                    isGood: allowsArbitraryLoads == true
                )
                diagnosticRow(
                    label: "NSAllowsArbitraryLoadsInWebContent",
                    value: allowsArbitraryLoadsInWebContent,
                    isGood: allowsArbitraryLoadsInWebContent == nil
                )
                diagnosticRow(
                    label: "NSAllowsLocalNetworking",
                    value: allowsLocalNetworking,
                    isGood: allowsLocalNetworking == nil
                )
            } header: {
                Text("Stato reale del binario in esecuzione")
            } footer: {
                Text("Questi valori sono letti direttamente da Bundle.main.infoDictionary sul dispositivo, non dal codice sorgente. Se \"NSAllowsArbitraryLoads\" non risulta true qui, la build installata non contiene ancora il fix più recente: disinstalla completamente l'app e reinstalla da una build fresca.")
                    .font(.caption2)
            }

            Section("Info aggiuntive") {
                LabeledContent("Bundle version", value: bundleVersion)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "sconosciuto")
            }
        }
        .navigationTitle("Diagnostica rete (ATS)")
    }

    private var atsDict: [String: Any]? {
        Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
    }

    private var allowsArbitraryLoads: Bool? { atsDict?["NSAllowsArbitraryLoads"] as? Bool }
    private var allowsArbitraryLoadsInWebContent: Bool? { atsDict?["NSAllowsArbitraryLoadsInWebContent"] as? Bool }
    private var allowsLocalNetworking: Bool? { atsDict?["NSAllowsLocalNetworking"] as? Bool }

    private var bundleVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @ViewBuilder
    private func diagnosticRow(label: String, value: Bool?, isGood: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 13, design: .monospaced))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: isGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isGood ? .green : .red)
                Text(value == nil ? "assente" : (value! ? "true" : "false"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
