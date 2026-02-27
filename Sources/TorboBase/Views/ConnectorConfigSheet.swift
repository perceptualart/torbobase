#if canImport(SwiftUI)
import SwiftUI

struct ConnectorConfigSheet: View {
    let connector: ConnectorDefinition
    @Binding var connectorStates: [String: Bool]

    @Environment(\.dismiss) private var dismiss
    @State private var fieldValues: [String: String] = [:]
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: connector.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        Text(connector.category.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))

                        if connectorStates[connector.id] == true {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                Text("Connected")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.green.opacity(0.8))
                            }
                        }
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(Color.white.opacity(0.06))

            // Description
            Text(connector.description)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                // Config fields
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(connector.configFields, id: \.id) { field in
                            configFieldView(field)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }

            Divider().overlay(Color.white.opacity(0.06))

            // Buttons
            HStack(spacing: 12) {
                if connectorStates[connector.id] == true {
                    Button {
                        Task { await disconnect() }
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text("Save & Connect")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(20)
        }
        .frame(width: 420)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await loadConfig() }
    }

    // MARK: - Field View

    @ViewBuilder
    private func configFieldView(_ field: ConnectorConfigField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            if field.isSecret {
                SecureField(field.placeholder, text: binding(for: field.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                TextField(field.placeholder, text: binding(for: field.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !field.helpText.isEmpty {
                Text(field.helpText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func binding(for fieldID: String) -> Binding<String> {
        Binding(
            get: { fieldValues[fieldID] ?? "" },
            set: { fieldValues[fieldID] = $0 }
        )
    }

    // MARK: - Actions

    private func loadConfig() async {
        let config = await ConnectorStore.shared.getAllConfig(connector.id)
        await MainActor.run {
            fieldValues = config
            isLoading = false
        }
    }

    private func save() async {
        isSaving = true
        let store = ConnectorStore.shared
        for (key, value) in fieldValues {
            await store.setConfig(connector.id, key: key, value: value)
        }
        await store.enable(connector.id)
        await MainActor.run {
            connectorStates[connector.id] = true
            isSaving = false
            dismiss()
        }
    }

    private func disconnect() async {
        let store = ConnectorStore.shared
        await store.disable(connector.id)
        await store.clearConfig(connector.id)
        await MainActor.run {
            connectorStates[connector.id] = false
            dismiss()
        }
    }
}
#endif
