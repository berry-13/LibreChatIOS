import DesignKit
import LibreChatDomain
import SwiftUI

struct LoginView: View {
    let model: AppModel

    @State private var email = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var errorMessage: String?
    @State private var presentedSheet: LoginSheet?
    @State private var isShowingServerChange = false
    @State private var socialLogin: SocialLoginPresentation?
    @State private var emailVerificationRecovery: EmailVerificationRecovery?
    @State private var emailVerificationTask: Task<Void, Never>?
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
        case twoFactor
    }

    /// LibreChat's continue green (Tailwind green-600, #16a34a).
    private static let libreChatGreen = Color(red: 0.086, green: 0.639, blue: 0.290)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 44)

                Image("LogoMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    // Softly rounded — clearly not a square, not a circle.
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(model.pendingTwoFactorToken == nil ? "Welcome back" : "Two-factor authentication")
                        .font(.largeTitle.bold())
                    if let server = model.selectedServer {
                        Button {
                            isShowingServerChange = true
                        } label: {
                            HStack(spacing: 5) {
                                ServerBadge(name: server.displayName, isSecure: server.baseURL.scheme == "https")
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isWorking)
                        .accessibilityLabel("Server: \(server.displayName)")
                        .accessibilityHint("Opens the server switcher. Cancelling it changes nothing.")
                        .accessibilityIdentifier("server-switch-button")
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    if model.pendingTwoFactorToken == nil {
                        if model.canUseEmailLogin {
                            TextField("Email", text: $email)
                                .textContentType(.username)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .focused($focusedField, equals: .email)
                                .onSubmit { focusedField = .password }
                                .loginFieldStyle()

                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focusedField, equals: .password)
                                .onSubmit(signIn)
                                .loginFieldStyle()
                        } else {
                            Label(
                                "This server has disabled email and password sign-in.",
                                systemImage: "envelope.slash"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Enter the code from your authenticator app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Authentication code", text: $twoFactorCode)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.asciiCapable)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .twoFactor)
                            .onSubmit(verifyTwoFactor)
                            .loginFieldStyle()
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let notice = model.notice {
                        Label(notice, systemImage: "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let recovery = emailVerificationRecovery {
                        emailVerificationRecoveryView(recovery)
                    }

                    if model.pendingTwoFactorToken != nil || model.canUseEmailLogin {
                        // LibreChat's green continue button. green-600 (not the
                        // brighter green-500) keeps the white label above the
                        // 3:1 large-text contrast threshold in both themes.
                        Button(action: primaryAction) {
                            HStack {
                                if model.isWorking { ProgressView() }
                                Text(primaryButtonTitle)
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(GreenContinueButtonStyle())
                        .disabled(!canSubmit || model.isWorking)
                        .accessibilityLabel(primaryButtonTitle)
                        .accessibilityHint("Signs in to \(model.selectedServer?.displayName ?? "this server").")
                        .accessibilityIdentifier("sign-in")
                    }

                    if model.pendingTwoFactorToken == nil,
                       model.canRegisterAccount || model.canRequestPasswordReset {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                if model.canRegisterAccount {
                                    registrationButton
                                }
                                Spacer(minLength: 0)
                                if model.canRequestPasswordReset {
                                    passwordResetButton
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                if model.canRegisterAccount {
                                    registrationButton
                                }
                                if model.canRequestPasswordReset {
                                    passwordResetButton
                                }
                            }
                        }
                        .font(.footnote)
                        .disabled(model.isWorking)
                    }

                    if model.pendingTwoFactorToken == nil,
                       model.registrationRequiresBrowserChallenge {
                        Label(
                            "Account creation requires this server’s browser challenge and is not available in the native app yet.",
                            systemImage: "safari"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.pendingTwoFactorToken == nil, !model.browserAuthenticationMethods.isEmpty {
                        Divider()
                        ForEach(model.browserAuthenticationMethods, id: \.self) { method in
                            Button {
                                browserSignIn(method)
                            } label: {
                                HStack(spacing: 10) {
                                    providerIcon(method)
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text("Continue with \(providerName(method))")
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isWorking)
                        }
                    }

                    if model.pendingTwoFactorToken != nil {
                        Button("Back to sign in") {
                            errorMessage = nil
                            twoFactorCode = ""
                            model.cancelTwoFactor()
                            focusedField = .email
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: 520)

                if model.selectedServer != nil, model.repository != nil {
                    // Guest mode: browse a publicly shared conversation without
                    // an account, like LibreChat's anonymous share pages.
                    Button {
                        if let server = model.selectedServer, let repository = model.repository {
                            presentedSheet = .sharedLink(server: server, repository: repository)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                            Text("Continue as guest")
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .disabled(model.isWorking)
                    .accessibilityLabel("Continue as guest")
                    .accessibilityHint("Opens a publicly shared conversation without signing in.")
                    .accessibilityIdentifier("guest-shared-chat")
                }

                legalLinks

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            #if DEBUG
            // UI-test seeding: prefill the form from the launch environment so
            // E2E runs never depend on synthesized hardware-keyboard focus.
            if email.isEmpty, let seededEmail = ProcessInfo.processInfo.environment["E2E_EMAIL"] {
                email = seededEmail
            }
            if password.isEmpty, let seededPassword = ProcessInfo.processInfo.environment["E2E_PASSWORD"] {
                password = seededPassword
            }
            if ProcessInfo.processInfo.environment["E2E_AUTOLOGIN"] == "1",
               canSubmit, !model.isWorking {
                Task { @MainActor in primaryAction() }
            }
            #endif
            if model.pendingTwoFactorToken != nil {
                focusedField = .twoFactor
            } else if model.canUseEmailLogin {
                focusedField = .email
            }
        }
        .onChange(of: email) { _, newValue in
            guard let recoveryEmail = emailVerificationRecovery?.email,
                  canonicalEmail(recoveryEmail) != canonicalEmail(newValue) else { return }
            emailVerificationTask?.cancel()
            emailVerificationTask = nil
            emailVerificationRecovery = nil
        }
        .onChange(of: errorMessage) { _, message in
            if let announcement = errorAnnouncementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .onDisappear {
            emailVerificationTask?.cancel()
            emailVerificationTask = nil
        }
        .alert("Replace account for this profile?", isPresented: replacementAlert) {
            Button("Cancel", role: .cancel) { Task { await model.cancelAccountReplacement() } }
            Button("Replace", role: .destructive) { Task { await model.confirmAccountReplacement() } }
        } message: {
            Text("Replacing the account purges this profile’s old local cache. Add another profile instead if you want to keep both accounts.")
        }
        .sheet(isPresented: $isShowingServerChange) {
            ServerChangeSheet(model: model)
        }
        .sheet(item: $socialLogin) { presentation in
            if let profile = model.selectedServer {
                InAppOAuthSheet(
                    profile: profile,
                    provider: presentation.provider
                ) { cookies in
                    Task {
                        do {
                            try await model.adoptSocialSession(cookies: cookies)
                        } catch {
                            errorMessage = error.userFacingMessage
                        }
                    }
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            Group {
                switch sheet {
                case .passwordReset:
                    PasswordResetRequestView(model: model)
                case .registration:
                    AccountRegistrationView(model: model)
                case let .sharedLink(server, repository):
                    SharedLinkEntryView(
                        baseURL: server.baseURL,
                        repository: repository,
                        canFork: false,
                        onUnauthorized: {},
                        onForked: { _ in }
                    )
                }
            }
        }
    }

    private var canSubmit: Bool {
        if model.pendingTwoFactorToken != nil {
            return !twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private var primaryButtonTitle: String {
        if model.isWorking { return "Signing in…" }
        return model.pendingTwoFactorToken == nil ? "Sign in" : "Verify"
    }

    private func primaryAction() {
        if model.pendingTwoFactorToken == nil {
            signIn()
        } else {
            verifyTwoFactor()
        }
    }

    private func signIn() {
        guard canSubmit, !model.isWorking else { return }
        errorMessage = nil
        emailVerificationTask?.cancel()
        emailVerificationTask = nil
        emailVerificationRecovery = nil
        let submittedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.signIn(
                    email: submittedEmail,
                    password: password
                )
                password = ""
                if model.pendingTwoFactorToken != nil {
                    focusedField = .twoFactor
                }
            } catch AuthenticationLoginError.emailVerificationRequired {
                password = ""
                guard canonicalEmail(email) == canonicalEmail(submittedEmail) else { return }
                emailVerificationRecovery = .required(email: submittedEmail)
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }

    @ViewBuilder
    private func emailVerificationRecoveryView(_ recovery: EmailVerificationRecovery) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Email verification required", systemImage: "envelope.badge")
                .font(.subheadline.weight(.semibold))

            switch recovery {
            case .required:
                Text(
                    model.canResendEmailVerification
                        ? "Use the verification link from this server, or request a new one."
                        : "Use the verification link from this server, then return to sign in."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if model.canResendEmailVerification {
                    Button("Resend verification email", action: resendVerificationEmail)
                        .buttonStyle(.bordered)
                        .accessibilityHint("Requests one new verification link and invalidates the previous link")
                }

            case .sending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Requesting a new verification email…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

            case let .sent(_, message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("email-verification-recovery")
    }

    private func resendVerificationEmail() {
        guard case let .required(email) = emailVerificationRecovery,
              model.canResendEmailVerification,
              emailVerificationTask == nil else { return }
        errorMessage = nil
        emailVerificationRecovery = .sending(email: email)
        emailVerificationTask = Task {
            defer { emailVerificationTask = nil }
            do {
                let result = try await model.resendEmailVerification(email: email)
                try Task.checkCancellation()
                let message = result.notice.message?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                emailVerificationRecovery = .sent(
                    email: email,
                    message: message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "Check your email for a new verification link."
                )
            } catch is CancellationError {
                return
            } catch {
                emailVerificationRecovery = .required(email: email)
                errorMessage = error.userFacingMessage
            }
        }
    }

    private func canonicalEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func verifyTwoFactor() {
        guard canSubmit, !model.isWorking else { return }
        errorMessage = nil
        Task {
            do {
                try await model.verifyTwoFactor(
                    code: twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }

    private func browserSignIn(_ method: AuthenticationMethod) {
        errorMessage = nil
        guard model.supportsBrowserAuthentication else {
            // Stock servers expose no mobile token exchange; run the
            // provider flow in-app and adopt the session cookies.
            socialLogin = SocialLoginPresentation(provider: method)
            return
        }
        Task {
            do { try await model.signIn(using: method) }
            catch { errorMessage = error.userFacingMessage }
        }
    }

    private func providerName(_ method: AuthenticationMethod) -> String {
        switch method {
        case .openID: "OpenID Connect"
        case .saml: "SAML"
        default: method.rawValue.capitalized
        }

    }

    /// LibreChat's web login shows each enabled provider's own logo next to
    /// its button. Known providers use bundled brand marks; the rest fall
    /// back to neutral glyphs.
    @ViewBuilder
    private func providerIcon(_ method: AuthenticationMethod) -> some View {
        switch method {
        case .google:
            Image("ProviderGoogle").resizable().scaledToFit()
        case .facebook:
            Image("ProviderFacebook").resizable().scaledToFit()
        case .discord:
            Image("ProviderDiscord").resizable().scaledToFit()
        case .github:
            Image("ProviderGithub")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
        case .apple:
            Image("ProviderApple")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
        case .ldap:
            Image(systemName: "person.text.rectangle").foregroundStyle(.primary)
        case .openID:
            Image(systemName: "key.horizontal").foregroundStyle(.primary)
        case .saml:
            Image(systemName: "checkmark.seal").foregroundStyle(.primary)
        case .email:
            Image(systemName: "envelope").foregroundStyle(.primary)
        }
    }

    private var registrationButton: some View {
        Button("Create account") {
            presentedSheet = .registration
        }
        .accessibilityHint("Opens native registration for this LibreChat server.")
    }

    private var passwordResetButton: some View {
        Button("Forgot password?") {
            presentedSheet = .passwordReset
        }
        .accessibilityHint("Opens password recovery for this LibreChat server.")
    }

    private var replacementAlert: Binding<Bool> {
        Binding(
            get: { model.pendingAccountReplacement != nil },
            set: { value in
                if !value { Task { await model.cancelAccountReplacement() } }
            }
        )
    }

    @ViewBuilder
    private var legalLinks: some View {
        let configuration = model.publicLegalConfiguration
        if configuration?.privacyPolicy != nil || configuration?.termsOfService?.externalURL != nil {
            HStack(spacing: 18) {
                if let privacy = configuration?.privacyPolicy {
                    Link("Privacy", destination: privacy.externalURL)
                }
                if let termsURL = configuration?.termsOfService?.externalURL {
                    Link("Terms", destination: termsURL)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private enum EmailVerificationRecovery: Equatable {
    case required(email: String)
    case sending(email: String)
    case sent(email: String, message: String)

    var email: String {
        switch self {
        case let .required(email), let .sending(email), let .sent(email, _):
            email
        }
    }
}

private enum LoginSheet: Identifiable {
    case passwordReset
    case registration
    case sharedLink(server: ServerProfile, repository: LibreChatRepository)

    var id: String {
        switch self {
        case .passwordReset: "password-reset"
        case .registration: "registration"
        case let .sharedLink(server, _): "shared-link-\(server.id.rawValue)"
        }
    }
}

private struct AccountRegistrationView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmationPassword = ""
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?
    @State private var result: RegistrationResult?
    @State private var errorMessage: String?
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case email
        case username
        case password
        case confirmation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        Label(
                            model.registrationUsesEmailDelivery ? "Check your email" : "Registration submitted",
                            systemImage: model.registrationUsesEmailDelivery ? "envelope.badge" : "person.crop.circle.badge.checkmark"
                        )
                        .font(.title2.bold())

                        Text(successMessage(for: result))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Return to sign in") { dismiss() }
                            .adaptiveProminentButtonStyle()
                    } else {
                        Text("Create a local account for this LibreChat server. Registration does not sign you in automatically.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("Name", text: $name)
                            .textContentType(.name)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit { focusedField = .email }
                            .loginFieldStyle()

                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .email)
                            .onSubmit { focusedField = .username }
                            .loginFieldStyle()

                        if !trimmedEmail.isEmpty,
                           !AccountInputValidation.isPlausibleEmail(trimmedEmail) {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        TextField("Username (optional)", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                            .loginFieldStyle()

                        SecureField("Password", text: $password)
                            .textContentType(.newPassword)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .password)
                            .onSubmit { focusedField = .confirmation }
                            .loginFieldStyle()

                        SecureField("Confirm password", text: $confirmationPassword)
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .confirmation)
                            .onSubmit(submit)
                            .loginFieldStyle()

                        Text(passwordRequirement)
                            .font(.caption)
                            .foregroundStyle(
                                passwordsAreValid || password.isEmpty
                                    ? Color.secondary
                                    : Color.red
                            )
                            .fixedSize(horizontal: false, vertical: true)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                        }

                        Button(action: submit) {
                            HStack {
                                if isSubmitting { ProgressView() }
                                Text(isSubmitting ? "Creating account…" : "Create account")
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(minHeight: 36)
                        }
                        .adaptiveProminentButtonStyle()
                        .disabled(!isValid || isSubmitting)
                    }
                }
                .padding(22)
                .frame(maxWidth: 520)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Create account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { focusedField = result == nil ? .name : nil }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { clearSecrets() }
            }
            .onDisappear {
                submissionTask?.cancel()
                submissionTask = nil
                isSubmitting = false
                errorMessage = nil
                clearSecrets()
                name = ""
                email = ""
                username = ""
                result = nil
            }
        }
        .presentationDetents([.large])
        .onChange(of: errorMessage) { _, message in
            if let announcement = errorAnnouncementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var minimumPasswordLength: Int { max(8, model.registrationMinimumPasswordLength) }
    private var passwordsAreValid: Bool {
        password.count >= minimumPasswordLength
            && password.count <= 128
            && password == confirmationPassword
    }
    private var isValid: Bool {
        (3...80).contains(trimmedName.count)
            && AccountInputValidation.isPlausibleEmail(trimmedEmail)
            && (trimmedUsername.isEmpty || (2...80).contains(trimmedUsername.count))
            && passwordsAreValid
    }
    private var passwordRequirement: String {
        if !confirmationPassword.isEmpty, password != confirmationPassword {
            return "Passwords do not match."
        }
        return "Use between \(minimumPasswordLength) and 128 characters."
    }

    private func successMessage(for result: RegistrationResult) -> String {
        if let message = result.notice.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        return model.registrationUsesEmailDelivery
            ? "Follow the verification instructions from this server, then return to sign in."
            : "Return to sign in with the account you created."
    }

    private func clearSecrets() {
        password = ""
        confirmationPassword = ""
    }

    private func submit() {
        guard isValid, !isSubmitting, submissionTask == nil else { return }
        errorMessage = nil
        isSubmitting = true
        let registration = AccountRegistration(
            name: trimmedName,
            email: trimmedEmail,
            username: trimmedUsername.isEmpty ? nil : trimmedUsername,
            password: password,
            confirmationPassword: confirmationPassword
        )
        submissionTask = Task {
            defer {
                isSubmitting = false
                submissionTask = nil
                clearSecrets()
            }
            do {
                let submitted = try await model.registerAccount(registration)
                try Task.checkCancellation()
                result = submitted
                name = ""
                email = ""
                username = ""
                focusedField = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct PasswordResetRequestView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var isSubmitting = false
    @State private var submissionTask: Task<Void, Never>?
    @State private var result: PasswordResetRequestResult?
    @State private var errorMessage: String?
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let result {
                        Label("Check your email", systemImage: "envelope.badge")
                            .font(.title2.bold())
                        Text("If an account with that email exists, LibreChat has prepared password-recovery instructions.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let recoveryURL = result.recoveryURL {
                            Text("This server returned a one-time recovery link because email delivery is unavailable. The link stays only on this screen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Open reset link", systemImage: "arrow.up.right.square") {
                                openURL(recoveryURL)
                            }
                            .adaptiveProminentButtonStyle()
                        }

                        Button("Done") { dismiss() }
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Enter the email address used for this LibreChat server. The response is intentionally the same whether or not an account exists.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($isEmailFocused)
                            .onSubmit(submit)
                            .loginFieldStyle()

                        if !trimmedEmail.isEmpty,
                           !AccountInputValidation.isPlausibleEmail(trimmedEmail) {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                        }

                        Button(action: submit) {
                            HStack {
                                if isSubmitting { ProgressView() }
                                Text(isSubmitting ? "Requesting…" : "Send recovery instructions")
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(minHeight: 36)
                        }
                        .adaptiveProminentButtonStyle()
                        .disabled(!AccountInputValidation.isPlausibleEmail(trimmedEmail) || isSubmitting)
                    }
                }
                .padding(22)
                .frame(maxWidth: 520)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { isEmailFocused = result == nil }
            .onDisappear {
                submissionTask?.cancel()
                submissionTask = nil
                isSubmitting = false
                errorMessage = nil
                email = ""
                result = nil
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: errorMessage) { _, message in
            if let announcement = errorAnnouncementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard AccountInputValidation.isPlausibleEmail(trimmedEmail),
              !isSubmitting,
              submissionTask == nil else { return }
        errorMessage = nil
        isSubmitting = true
        submissionTask = Task {
            defer {
                isSubmitting = false
                submissionTask = nil
            }
            do {
                let submitted = try await model.requestPasswordReset(email: trimmedEmail)
                try Task.checkCancellation()
                result = submitted
                email = ""
                isEmailFocused = false
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private enum AccountInputValidation {
    static func isPlausibleEmail(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else { return false }
        return parts[1].contains(".")
    }
}

/// LibreChat's green continue button: explicit green-600 fill with a
/// semibold white label (3.3:1 contrast, above the large-text AA threshold).
struct GreenContinueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.086, green: 0.639, blue: 0.290))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Non-destructive server switcher: cancel changes nothing — no session
/// teardown, no refresh. Switching only happens when an explicit connect or
/// saved-profile selection succeeds.
private struct ServerChangeSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverAddress = ""
    @State private var errorMessage: String?

    private var otherProfiles: [ServerProfile] {
        model.profiles.filter { $0.id != model.selectedServer?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let current = model.selectedServer {
                    Section("Current server") {
                        Text(current.displayName)
                    }
                }

                Section {
                    TextField("chat.example.com", text: $serverAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.continue)
                        .onSubmit(connect)
                        .accessibilityIdentifier("server-change-address")
                } header: {
                    Text("Switch server")
                } footer: {
                    Text("Remote servers must use HTTPS. Cancelling keeps everything unchanged.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !otherProfiles.isEmpty {
                    Section("Saved servers") {
                        ForEach(otherProfiles) { profile in
                            Button {
                                Task {
                                    await model.select(profile: profile)
                                    dismiss()
                                }
                            } label: {
                                Label(profile.displayName, systemImage: "server.rack")
                            }
                            .disabled(model.isWorking)
                            .accessibilityLabel("Switch to \(profile.displayName)")
                        }
                    }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { connect() }
                        .disabled(
                            model.isWorking
                                || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .onAppear {
                guard serverAddress.isEmpty, let baseURL = model.selectedServer?.baseURL else { return }
                serverAddress = baseURL.absoluteString
            }
        }
    }

    private func connect() {
        guard !model.isWorking else { return }
        errorMessage = nil
        Task {
            do {
                try await model.connect(to: serverAddress)
                dismiss()
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private extension View {
    func loginFieldStyle() -> some View {
        padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
