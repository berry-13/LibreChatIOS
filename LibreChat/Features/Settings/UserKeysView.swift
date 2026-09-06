import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI

@MainActor
@Observable
final class UserKeysModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let repository: any UserKeyRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void

    private(set) var state: State = .idle
    /// Confirmed mutations advance this so a provider-status refresh that
    /// captured pre-mutation state can never overwrite the newer result.
    private var refreshRevision = 0
    private(set) var catalog: UserKeyCatalog?
    private(set) var activeMutation: UserKeyEndpointID?
    private(set) var operationMessage: String?

    init(
        repository: any UserKeyRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard !isOffline() else {
            catalog = nil
            state = .offline
            return
        }
        if catalog == nil { state = .loading }
        refreshRevision &+= 1
        let revision = refreshRevision
        do {
            let fresh = try await repository.userKeyCatalog()
            guard revision == refreshRevision else { return }
            catalog = fresh
            operationMessage = nil
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard revision == refreshRevision else { return }
            await handle(error, clearCatalog: true)
        }
    }

    func save(
        requirement: UserKeyRequirement,
        credentials: UserKeyCredentials,
        expiration: UserKeyExpirationPreset,
        now: Date = Date()
    ) async -> Bool {
        guard state == .loaded,
              !isOffline(),
              activeMutation == nil,
              catalog?.requirements.contains(where: {
                  $0.id == requirement.id && $0.form == requirement.form
              }) == true else { return false }
        activeMutation = requirement.id
        operationMessage = nil
        defer { activeMutation = nil }
        do {
            let result = try await repository.saveUserKey(UserKeyUpdateInput(
                endpointID: requirement.id,
                credentials: credentials,
                expiresAt: expiration.expirationDate(relativeTo: now)
            ))
            switch result {
            case let .confirmed(availability):
                install(availability, for: requirement.id)
                await refreshAfterConfirmedMutation()
                return true
            case .deliveryUncertain:
                operationMessage = "LibreChat may have received the credential. It was not sent again. Refresh status before deciding whether to replace it."
                return false
            }
        } catch {
            await handle(error, clearCatalog: error.isUnauthorized)
            return false
        }
    }

    func revoke(_ requirement: UserKeyRequirement) async -> Bool {
        guard state == .loaded,
              !isOffline(),
              activeMutation == nil,
              catalog?.requirements.contains(where: { $0.id == requirement.id }) == true else {
            return false
        }
        activeMutation = requirement.id
        operationMessage = nil
        defer { activeMutation = nil }
        do {
            let result = try await repository.revokeUserKey(requirement.id)
            switch result {
            case .confirmed(.missing):
                install(.missing, for: requirement.id)
                await refreshAfterConfirmedMutation()
                return true
            case .confirmed, .deliveryUncertain:
                operationMessage = "LibreChat could not prove the credential was removed. It was not sent again. Refresh its status before retrying."
                return false
            }
        } catch {
            await handle(error, clearCatalog: error.isUnauthorized)
            return false
        }
    }

    private func install(_ availability: UserKeyAvailability, for endpointID: UserKeyEndpointID) {
        guard var catalog,
              let index = catalog.requirements.firstIndex(where: { $0.id == endpointID }) else {
            return
        }
        catalog.requirements[index].availability = availability
        catalog.fetchedAt = Date()
        self.catalog = catalog
    }

    private func refreshAfterConfirmedMutation() async {
        // Supersedes any provider refresh that captured pre-mutation state.
        refreshRevision &+= 1
        do {
            catalog = try await repository.userKeyCatalog()
            state = .loaded
        } catch {
            if error.isUnauthorized {
                await handle(error, clearCatalog: true)
            } else {
                state = .loaded
                operationMessage = "The change was confirmed, but provider status could not be refreshed."
            }
        }
    }

    private func handle(_ error: Error, clearCatalog: Bool) async {
        guard !(error is CancellationError) else { return }
        if clearCatalog { catalog = nil }
        if error.isUnauthorized {
            state = .unauthorized
            operationMessage = nil
            await onUnauthorized()
        } else {
            state = catalog == nil ? .failed(error.userFacingMessage) : .loaded
            operationMessage = error.userFacingMessage
        }
    }
}

struct UserKeysView: View {
    @State private var model: UserKeysModel
    @State private var editor: UserKeyRequirement?
    @State private var pendingRevocation: UserKeyRequirement?

    init(appModel: AppModel, repository: any UserKeyRepository) {
        _model = State(initialValue: UserKeysModel(
            repository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: appModel.expireSessionCallback()
        ))
    }

    var body: some View {
        List {
            content
        }
        .navigationTitle("Provider credentials")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .sheet(item: $editor) { requirement in
            UserKeyEditorView(requirement: requirement) { credentials, expiration in
                await model.save(
                    requirement: requirement,
                    credentials: credentials,
                    expiration: expiration
                )
            }
        }
        .confirmationDialog(
            "Remove provider credential?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            presenting: pendingRevocation
        ) { requirement in
            Button("Remove \(requirement.displayName) credential", role: .destructive) {
                pendingRevocation = nil
                Task { _ = await model.revoke(requirement) }
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: { requirement in
            Text("This disables targets that require your \(requirement.displayName) credential until you add another one.")
        }
        .accessibilityIdentifier("provider-credentials")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 5, horizontalPadding: 0, accessibilityLabel: "Loading provider status…")
                .listRowSeparator(.hidden)
        case .offline:
            ContentUnavailableView(
                "Credentials need a network",
                systemImage: "wifi.slash",
                description: Text("Provider credential status and changes are never served from the offline cache.")
            )
            .listRowSeparator(.hidden)
        case .unauthorized:
            ContentUnavailableView(
                "Session expired",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in again to manage provider credentials.")
            )
            .listRowSeparator(.hidden)
        case let .failed(message):
            ContentUnavailableView {
                Label("Provider status unavailable", systemImage: "key.horizontal")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
            .listRowSeparator(.hidden)
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let operationMessage = model.operationMessage {
            Section {
                Label(operationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-credential-operation-message")
            }
        }

        if model.catalog?.requirements.isEmpty != false {
            ContentUnavailableView(
                "No credentials requested",
                systemImage: "key.horizontal",
                description: Text("This LibreChat server does not currently advertise a native-compatible user-provided provider credential.")
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(model.catalog?.requirements ?? []) { requirement in
                    UserKeyRequirementRow(
                        requirement: requirement,
                        isBusy: model.activeMutation == requirement.id,
                        onConfigure: { editor = requirement },
                        onRevoke: { pendingRevocation = requirement }
                    )
                }
            } header: {
                Text("Required by this server")
            } footer: {
                Text("LibreChat encrypts submitted values on the server. This app never reads them back or saves a local copy.")
            }
        }
    }
}

private struct UserKeyRequirementRow: View {
    let requirement: UserKeyRequirement
    let isBusy: Bool
    let onConfigure: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(requirement.displayName)
                        .font(.body.weight(.semibold))
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            HStack {
                Button(requirement.availability.isUsable ? "Replace" : "Add credential") {
                    onConfigure()
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(isBusy)
                .accessibilityHint("Opens a private editor. Existing secret values are never displayed.")

                if requirement.availability.isUsable {
                    Button("Remove", role: .destructive) { onRevoke() }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .disabled(isBusy)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-credential-\(requirement.id.rawValue)")
    }

    private var statusText: String {
        switch requirement.availability {
        case .missing: "Not configured"
        case .stored(nil): "Configured · no expiration"
        case let .stored(date?): "Configured · expires \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .expired(date): "Expired \(date.formatted(date: .abbreviated, time: .omitted))"
        case .unavailable: "Status unavailable"
        }
    }

    private var statusColor: Color {
        switch requirement.availability {
        case .stored: .secondary
        case .expired: .orange
        case .missing, .unavailable: .secondary
        }
    }
}

private struct UserKeyEditorView: View {
    let requirement: UserKeyRequirement
    let onSave: @MainActor (UserKeyCredentials, UserKeyExpirationPreset) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var expiration: UserKeyExpirationPreset = .twelveHours
    @State private var primarySecret = ""
    @State private var baseURL = ""
    @State private var instanceName = ""
    @State private var deploymentName = ""
    @State private var apiVersion = ""
    @State private var serviceAccountJSON = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var sessionToken = ""
    @State private var bearerToken = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Existing values cannot be shown. Saving replaces the credential for this account.",
                        systemImage: "lock.shield"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                credentialFields

                Section("Expiration") {
                    Picker("Keep credential for", selection: $expiration) {
                        ForEach(UserKeyExpirationPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(requirement.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clearSecrets(); dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                        .accessibilityIdentifier("save-provider-credential")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearSecrets() }
        }
        .onDisappear { clearSecrets() }
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch requirement.form {
        case .simple:
            Section("Credential") {
                SecureField("Provider key", text: $primarySecret)
                    .textContentType(.password)
                    .privacySensitive()
            }
        case let .openAI(allowsBaseURL):
            Section("Credential") {
                SecureField("API key", text: $primarySecret)
                    .textContentType(.password)
                    .privacySensitive()
                if allowsBaseURL {
                    TextField("API base URL (optional)", text: $baseURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        case .azureOpenAI:
            Section("Azure OpenAI") {
                SecureField("API key", text: $primarySecret)
                    .textContentType(.password)
                    .privacySensitive()
                TextField("Instance name", text: $instanceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Deployment name", text: $deploymentName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("API version", text: $apiVersion)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case .google:
            Section("Google") {
                SecureField("Google API key (optional)", text: $primarySecret)
                    .textContentType(.password)
                    .privacySensitive()
                SecureField("Service-account JSON (optional)", text: $serviceAccountJSON)
                    .textContentType(.password)
                    .privacySensitive()
                Text("Paste a complete service-account JSON document. It stays in memory only until you leave this editor or the app becomes inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .bedrock(requirements):
            Section("Amazon Bedrock") {
                if requirements.bearerToken {
                    SecureField("Bearer token (optional alternative)", text: $bearerToken)
                        .textContentType(.password)
                        .privacySensitive()
                }
                if requirements.accessKeyID {
                    SecureField("Access key ID", text: $accessKeyID)
                        .textContentType(.password)
                        .privacySensitive()
                }
                if requirements.secretAccessKey {
                    SecureField("Secret access key", text: $secretAccessKey)
                        .textContentType(.password)
                        .privacySensitive()
                }
                if requirements.sessionToken {
                    SecureField("Session token", text: $sessionToken)
                        .textContentType(.password)
                        .privacySensitive()
                }
                if requirements.bearerToken {
                    Text("A bearer token is used alone. Otherwise, enter every access-key field required by this server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        let credentials = credentials
        // The repository call receives a one-shot value. Clear every bound UI
        // field before the first suspension point so secrets cannot linger in
        // observable SwiftUI state during networking or backgrounding.
        clearSecrets()
        errorMessage = nil
        isSaving = true
        let didSave = await onSave(credentials, expiration)
        isSaving = false
        if didSave {
            dismiss()
        } else {
            errorMessage = "The credential was not confirmed. Review provider status before entering it again."
        }
    }

    private var credentials: UserKeyCredentials {
        switch requirement.form {
        case .simple:
            .simple(secret: primarySecret)
        case .openAI:
            .openAI(apiKey: primarySecret, baseURL: baseURL)
        case .azureOpenAI:
            .azureOpenAI(
                apiKey: primarySecret,
                instanceName: instanceName,
                deploymentName: deploymentName,
                apiVersion: apiVersion
            )
        case .google:
            .google(apiKey: primarySecret, serviceAccountJSON: serviceAccountJSON)
        case .bedrock:
            .bedrock(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken,
                bearerToken: bearerToken
            )
        }
    }

    private func clearSecrets() {
        primarySecret.removeAll(keepingCapacity: false)
        baseURL.removeAll(keepingCapacity: false)
        instanceName.removeAll(keepingCapacity: false)
        deploymentName.removeAll(keepingCapacity: false)
        apiVersion.removeAll(keepingCapacity: false)
        serviceAccountJSON.removeAll(keepingCapacity: false)
        accessKeyID.removeAll(keepingCapacity: false)
        secretAccessKey.removeAll(keepingCapacity: false)
        sessionToken.removeAll(keepingCapacity: false)
        bearerToken.removeAll(keepingCapacity: false)
    }
}

private extension UserKeyExpirationPreset {
    var displayName: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .twoHours: "2 hours"
        case .twelveHours: "12 hours"
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .never: "No expiration"
        }
    }
}
