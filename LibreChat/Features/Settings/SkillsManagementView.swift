import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SkillsManagementModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case forbidden
        case unauthorized
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case inactive = "Inactive"

        var id: Self { self }
    }

    struct PendingMutation: Equatable {
        let operationID: UUID
        let skillID: SkillID
        let requestedActive: Bool
    }

    private let repository: any SkillRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private var searchIndex: [SkillID: String] = [:]

    private(set) var state: State = .idle
    private(set) var catalog: AccountSkillCatalog?
    private(set) var pendingMutation: PendingMutation?
    private(set) var operationError: String?
    var query = ""
    var filter: Filter = .all

    init(
        repository: any SkillRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    var visibleSkills: [AccountSkillSummary] {
        let source = catalog?.skills ?? []
        let filtered = source.filter { skill in
            switch filter {
            case .all: true
            case .active: skill.isActive
            case .inactive: !skill.isActive
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return filtered }
        return filtered.filter { searchIndex[$0.id]?.contains(needle) == true }
    }

    var announcementMessage: String? {
        if let operationError { return operationError }
        if case let .failed(message) = state { return message }
        return nil
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard pendingMutation == nil else { return }
        guard !isOffline() else {
            clearCatalog()
            state = .offline
            return
        }
        state = .loading
        operationError = nil
        do {
            let snapshot = try await repository.accountSkillCatalog()
            guard !Task.isCancelled else { return }
            install(snapshot)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            clearCatalog()
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

    func displayedActive(for skill: AccountSkillSummary) -> Bool {
        guard let pendingMutation, pendingMutation.skillID == skill.id else {
            return skill.isActive
        }
        return pendingMutation.requestedActive
    }

    func canChange(_ skill: AccountSkillSummary) -> Bool {
        state == .loaded
            && pendingMutation == nil
            && skill.canChangeActivation
            && !isOffline()
    }

    func setActive(_ active: Bool, for skill: AccountSkillSummary) async {
        guard canChange(skill),
              let catalog,
              catalog.skill(id: skill.id) == skill else { return }
        guard active != skill.isActive else { return }

        let pending = PendingMutation(
            operationID: UUID(),
            skillID: skill.id,
            requestedActive: active
        )
        pendingMutation = pending
        operationError = nil
        defer {
            if pendingMutation?.operationID == pending.operationID {
                pendingMutation = nil
            }
        }

        do {
            let outcome = try await repository.setSkillActivation(SkillActivationRequest(
                profileID: catalog.profileID,
                accountID: catalog.accountID,
                skillID: skill.id,
                isActive: active
            ))
            guard pendingMutation?.operationID == pending.operationID else { return }
            switch outcome {
            case let .confirmed(snapshot):
                guard snapshot.profileID == catalog.profileID,
                      snapshot.accountID == catalog.accountID else {
                    clearCatalog()
                    state = .failed(SkillManagementError.reviewedScopeMismatch.localizedDescription)
                    return
                }
                install(snapshot)
                state = .loaded
                UIAccessibility.post(
                    notification: .announcement,
                    argument: active ? "Skill activated" : "Skill deactivated"
                )
            case let .notConfirmed(snapshot):
                guard snapshot.profileID == catalog.profileID,
                      snapshot.accountID == catalog.accountID else {
                    clearCatalog()
                    state = .failed(SkillManagementError.reviewedScopeMismatch.localizedDescription)
                    return
                }
                install(snapshot)
                state = .loaded
                operationError = "LibreChat did not confirm that change. The current server state is shown, and the app did not send it again."
            case .outcomeUnknown:
                clearCatalog()
                state = .failed(
                    "LibreChat may have received that change, but its current state could not be verified. Reload before trying again."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard pendingMutation?.operationID == pending.operationID else { return }
            if error.isUnauthorized {
                clearCatalog()
                state = .unauthorized
                await onUnauthorized()
            } else if case LibreChatProtocolError.httpStatus(403, _, _) = error {
                clearCatalog()
                state = .forbidden
            } else {
                operationError = error.userFacingMessage
            }
        }
    }

    private func install(_ snapshot: AccountSkillCatalog) {
        catalog = snapshot
        searchIndex = Dictionary(uniqueKeysWithValues: snapshot.skills.map { skill in
            let values = [
                skill.displayTitle,
                skill.name,
                skill.description,
                skill.category ?? "",
                skill.source.rawValue
            ]
            return (skill.id, values.joined(separator: "\n").lowercased())
        })
    }

    private func clearCatalog() {
        catalog = nil
        searchIndex = [:]
    }
}

struct SkillsManagementView: View {
    @State private var model: SkillsManagementModel
    @State private var announcementState = AccessibilityAnnouncementState()

    init(appModel: AppModel, repository: any SkillRepository) {
        _model = State(initialValue: SkillsManagementModel(
            repository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: { await appModel.expireSession() }
        ))
    }

    var body: some View {
        List {
            content
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search Skills")
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .onChange(of: model.announcementMessage) { _, message in
            if let announcement = announcementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .accessibilityIdentifier("skills-management")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 6, horizontalPadding: 0, accessibilityLabel: "Loading Skills…")
                .listRowSeparator(.hidden)
        case .offline:
            ContentUnavailableView(
                "Skills need a connection",
                systemImage: "wifi.slash",
                description: Text("Skill access and account activation are checked live and are not stored for offline management.")
            )
            .listRowSeparator(.hidden)
        case .forbidden:
            ContentUnavailableView(
                "Skills unavailable",
                systemImage: "lock.shield",
                description: Text("The current LibreChat role no longer allows using Skills.")
            )
            .listRowSeparator(.hidden)
        case .unauthorized:
            ContentUnavailableView(
                "Session expired",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in again to manage Skills.")
            )
            .listRowSeparator(.hidden)
        case let .failed(message):
            ContentUnavailableView {
                Label("Skills unavailable", systemImage: "wand.and.stars")
            } description: {
                Text(message)
            } actions: {
                Button("Reload") { Task { await model.reload() } }
            }
            .listRowSeparator(.hidden)
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        Section {
            Picker("Show Skills", selection: $model.filter) {
                ForEach(SkillsManagementModel.Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Account activation")
        }

        Section {
            if model.visibleSkills.isEmpty {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No Skills in this filter"
                        : "No matching Skills",
                    systemImage: "wand.and.stars",
                    description: Text(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Choose another activation filter."
                            : "Try a different name, category, or description."
                    )
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.visibleSkills) { skill in
                    SkillActivationRow(
                        skill: skill,
                        isActive: Binding(
                            get: { model.displayedActive(for: skill) },
                            set: { active in Task { await model.setActive(active, for: skill) } }
                        ),
                        isSaving: model.pendingMutation?.skillID == skill.id,
                        isDisabled: !model.canChange(skill)
                    )
                }
            }
        } header: {
            Text("Available to this account")
        } footer: {
            if model.pendingMutation != nil {
                ProgressView("Saving account Skill setting…")
            }
        }

        if let operationError = model.operationError {
            Section {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("skills-operation-error")
            }
        }
    }
}

private struct SkillActivationRow: View {
    let skill: AccountSkillSummary
    @Binding var isActive: Bool
    let isSaving: Bool
    let isDisabled: Bool

    var body: some View {
        Toggle(isOn: $isActive) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(skill.displayTitle)
                        .font(.body.weight(.semibold))
                    if !skill.isUserInvocable {
                        Text("Model only")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(skill.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(skill.activationBasis.displayName)
                    if skill.fileCount > 0 {
                        Text("\(skill.fileCount) file\(skill.fileCount == 1 ? "" : "s")")
                    }
                    if let category = skill.category { Text(category) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .disabled(isDisabled)
        .overlay(alignment: .trailing) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 50)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(skill.displayTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("skill-activation-\(skill.id.rawValue)")
    }

    private var accessibilityValue: String {
        var values = [isActive ? "Active" : "Inactive", skill.activationBasis.displayName]
        if !skill.isUserInvocable { values.append("Model only") }
        if isSaving { values.append("Saving") }
        return values.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        if !skill.canChangeActivation {
            return "This server-managed Skill cannot be changed from the native app."
        }
        if isSaving { return "Wait for LibreChat to confirm this account setting." }
        return isActive
            ? "Deactivates this Skill for the active LibreChat account."
            : "Activates this Skill for the active LibreChat account."
    }
}
