import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI

@MainActor
@Observable
final class MCPConnectionsModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case forbidden
        case unauthorized
        case failed(String)
    }

    private let repository: any MCPRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void

    private(set) var state: State = .idle
    private(set) var catalog: MCPConnectionCatalog?
    var query = ""

    init(
        repository: any MCPRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    var visibleConnections: [MCPConnection] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return catalog?.connections ?? [] }
        return (catalog?.connections ?? []).filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.description?.localizedCaseInsensitiveContains(normalized) == true
        }
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
        do {
            catalog = try await repository.mcpConnections()
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            catalog = nil
            if error.isUnauthorized {
                state = .unauthorized
                await onUnauthorized()
            } else if case LibreChatProtocolError.httpStatus(403, _, _) = error {
                state = .forbidden
            } else {
                state = .failed(error.userFacingMessage)
            }
        }
    }
}

struct MCPConnectionsView: View {
    @State private var model: MCPConnectionsModel

    init(appModel: AppModel, repository: any MCPRepository) {
        _model = State(initialValue: MCPConnectionsModel(
            repository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: { await appModel.expireSession() }
        ))
    }

    var body: some View {
        List {
            content
        }
        .navigationTitle("MCP Connections")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search MCP connections")
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .accessibilityIdentifier("mcp-connections")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 5, horizontalPadding: 0, accessibilityLabel: "Loading connections…")
                .listRowSeparator(.hidden)
        case .offline:
            ContentUnavailableView(
                "Connections need a network",
                systemImage: "wifi.slash",
                description: Text("Connection details and status are not stored for offline browsing.")
            )
            .listRowSeparator(.hidden)
        case .forbidden:
            ContentUnavailableView(
                "Connections unavailable",
                systemImage: "lock.shield",
                description: Text("Your current LibreChat role does not allow using MCP connections.")
            )
            .listRowSeparator(.hidden)
        case .unauthorized:
            ContentUnavailableView(
                "Session expired",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in again to view connections.")
            )
            .listRowSeparator(.hidden)
        case let .failed(message):
            ContentUnavailableView {
                Label("Connections unavailable", systemImage: "point.3.connected.trianglepath.dotted")
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
        if model.visibleConnections.isEmpty {
            ContentUnavailableView(
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No connections available"
                    : "No matching connections",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "This account does not currently have access to an MCP server."
                        : "Try a different name or description."
                )
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(model.visibleConnections) { connection in
                    NavigationLink {
                        MCPConnectionDetailView(connection: connection)
                    } label: {
                        MCPConnectionRow(connection: connection)
                    }
                }
            } header: {
                Text("Available to this account")
            } footer: {
                Text("LibreChat owns connection setup, credentials, and tool execution. This app shows only the server-reported state.")
            }
        }
    }
}

private struct MCPConnectionRow: View {
    let connection: MCPConnection

    var body: some View {
        HStack(spacing: 12) {
            // The MCP's identity leads the row — a rounded app-icon-style
            // tile carrying the server's initial. The connection state never
            // replaces the identity mark; it only tints the small trailing
            // dot.
            MCPConnectionIcon(title: connection.title)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(connection.connectionState.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if connection.requiresOAuth {
                    Text(connection.authorizationState.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            // Secondary status dot, mirroring the list's quiet state language.
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .accessibilityLabel(connection.connectionState.displayName)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connection.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens connection details.")
    }

    private var accessibilityValue: String {
        var values = [connection.connectionState.displayName]
        if connection.requiresOAuth { values.append(connection.authorizationState.displayName) }
        if connection.isAgentOnly { values.append("Available through agents only") }
        return values.joined(separator: ", ")
    }

    private var statusColor: Color {
        switch connection.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .error: .red
        case .disconnected, .unknown: .secondary
        }
    }
}

/// App-icon-style identity tile for an MCP server: rounded, strongly tinted,
/// seeded by the server title. LibreChat does not ship per-server logos, so
/// this deterministic monogram is the identity — never the connection-state
/// symbol.
struct MCPConnectionIcon: View {
    let title: String

    private var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        Text(initial)
            .font(.headline.weight(.semibold))
            .monospaced()
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct MCPConnectionDetailView: View {
    let connection: MCPConnection

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        MCPConnectionIcon(title: connection.title)
                            .accessibilityHidden(true)
                        Text(connection.title)
                            .font(.title2.bold())
                    }
                    if let description = connection.description {
                        Text(description)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Status") {
                LabeledContent("Connection", value: connection.connectionState.displayName)
                if connection.requiresOAuth {
                    LabeledContent("Authorization", value: connection.authorizationState.displayName)
                }
                if connection.inspectionFailed {
                    Label(
                        "LibreChat could not inspect this connection's tools.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Configuration") {
                LabeledContent("Transport", value: connection.transport.displayName)
                LabeledContent("Managed by", value: connection.source.displayName)
                LabeledContent(
                    "Availability",
                    value: connection.isAgentOnly ? "Agents only" : "Chat and agents"
                )
            }

            if connection.requiresOAuth,
               connection.authorizationState != .authorized,
               connection.authorizationState != .notRequired {
                Section("Sign-in") {
                    Label(
                        "Finish setup in this server's LibreChat web app.",
                        systemImage: "safari"
                    )
                    Text("Native connector authorization stays disabled until this deployment exposes a mobile-safe authorization flow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Connection URLs, secrets, authentication values, and tool payloads stay on the LibreChat server and are not shown or cached here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(connection.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mcp-connection-detail")
    }
}
