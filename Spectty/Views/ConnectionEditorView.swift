import SwiftUI

struct ConnectionEditorView: View {
    @Bindable var connection: ServerConnection
    let isNew: Bool
    let onSave: (ServerConnection) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $connection.name)
                        .textInputAutocapitalization(.never)
                    TextField("Host", text: $connection.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $connection.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section("Authentication") {
                    TextField("Username", text: $connection.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Method", selection: $connection.authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                }

                Section("Transport") {
                    Picker("Protocol", selection: $connection.transport) {
                        ForEach(TransportType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(isNew ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(connection)
                        dismiss()
                    }
                    .disabled(connection.host.isEmpty || connection.username.isEmpty)
                }
            }
        }
    }
}
