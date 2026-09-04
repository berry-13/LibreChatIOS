import SwiftUI
import UIKit

struct ServerSetupView: View {
    let model: AppModel

    @State private var serverAddress = ""
    @State private var errorMessage: String?
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 44)

                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Connect LibreChat")
                        .font(.largeTitle.bold())
                    Text("Use the address of your self-hosted LibreChat instance.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 16) {
                    TextField("chat.example.com", text: $serverAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.continue)
                        .focused($isAddressFocused)
                        .onSubmit(connect)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("server-address")

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: connect) {
                        HStack {
                            if model.isWorking {
                                ProgressView()
                            }
                            Text(model.isWorking ? "Checking server…" : "Continue")
                                .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: 36)
                    }
                    .buttonStyle(GreenContinueButtonStyle())
                    .disabled(model.isWorking || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connect-server")

                    Text("Remote servers must use HTTPS. Localhost can use HTTP for development.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(22)
                .adaptiveSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(maxWidth: 520)

                if !model.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved servers")
                            .font(.headline)
                        ForEach(model.profiles) { profile in
                            Button {
                                Task { await model.select(profile: profile) }
                            } label: {
                                Label(profile.displayName, systemImage: "server.rack")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isWorking)
                            .accessibilityLabel("Connect to \(profile.displayName)")
                        }
                    }
                    .padding(20)
                    .adaptiveSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .frame(maxWidth: 520)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height - 80)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            #if DEBUG
            // UI-test seeding: prefill the address from the launch environment
            // so E2E runs never depend on synthesized keyboard focus.
            if serverAddress.isEmpty,
               let seededAddress = ProcessInfo.processInfo.environment["E2E_SERVER"] {
                serverAddress = seededAddress
            }
            if ProcessInfo.processInfo.environment["E2E_AUTOLOGIN"] == "1",
               !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !model.isWorking {
                connect()
            }
            #endif
            isAddressFocused = true
        }
        .onChange(of: errorMessage) { _, message in
            if let announcement = errorAnnouncementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private func connect() {
        guard !model.isWorking else { return }
        errorMessage = nil
        Task {
            do {
                try await model.connect(to: serverAddress)
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}
