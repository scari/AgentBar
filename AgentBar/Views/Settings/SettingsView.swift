import SwiftUI

extension Notification.Name {
    static let limitsChanged = Notification.Name("AgentBarLimitsChanged")
    static let notificationsSettingsChanged = Notification.Name("AgentBarNotificationsSettingsChanged")
    static let usageHistoryChanged = Notification.Name("AgentBarUsageHistoryChanged")
}

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("refreshInterval") private var refreshInterval: Double = 60
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notificationTaskCompletedEnabled") private var notificationTaskCompletedEnabled = true
    @AppStorage("notificationInputRequiredEnabled") private var notificationInputRequiredEnabled = true
    @AppStorage("notificationCodexEventsEnabled") private var notificationCodexEventsEnabled = true
    @AppStorage("notificationClaudeHookEventsEnabled") private var notificationClaudeHookEventsEnabled = true
    @AppStorage("notificationOpencodeHookEventsEnabled") private var notificationOpencodeHookEventsEnabled = true
    @AppStorage("notificationShowMessagePreview") private var notificationShowMessagePreview = false
    @AppStorage(NotificationSoundMode.defaultsKey) private var notificationSoundMode = NotificationSoundMode.system.rawValue
    #if AGENTBAR_NOTIFICATION_SOUNDS
    @AppStorage("notificationSoundPackPath") private var notificationSoundPackPath: String = ""
    @AppStorage("notificationSoundVolume") private var notificationSoundVolume: Double = 0.7
    #endif

    @AppStorage("claudeEnabled") private var claudeEnabled = true
    @AppStorage("claudePlan") private var claudePlan: String = ClaudePlan.pro.rawValue

    @AppStorage("codexEnabled") private var codexEnabled = true
    @AppStorage("codexPlan") private var codexPlan: String = CodexPlan.pro.rawValue
    @AppStorage("codexFiveHourLimit") private var codexFiveHourLimit: Double = 10_000_000
    @AppStorage("codexWeeklyLimit") private var codexWeeklyLimit: Double = 100_000_000

    @AppStorage("geminiEnabled") private var geminiEnabled = true
    @AppStorage("geminiDailyLimit") private var geminiDailyLimit: Double = 1_000

    @AppStorage("copilotEnabled") private var copilotEnabled = true
    @AppStorage(CopilotCredentialSettings.manualPATEnabledKey) private var copilotManualPATEnabled = false

    @AppStorage("cursorEnabled") private var cursorEnabled = true
    @AppStorage("cursorPlan") private var cursorPlan: String = CursorPlan.pro.rawValue
    @AppStorage("cursorMonthlyLimit") private var cursorMonthlyLimit: Double = CursorPlan.pro.monthlyUsageLimitUSD

    @AppStorage("zaiEnabled") private var zaiEnabled = true
    @AppStorage(BuyMeACoffeeSettings.hideButtonKey) private var hideBuyMeACoffeeButton = false

    @State private var selectedTab: SettingsTab = .usage
    #if AGENTBAR_NOTIFICATION_SOUNDS
    @State private var showingSoundPackHelp = false
    @StateObject private var soundPackVM = SoundPackViewModel()
    #endif
    @State private var showingAgentSourcesHelp = false
    @State private var copilotPAT: String = ""
    @State private var hasSavedCopilotPAT = false
    @State private var zaiAPIKey: String = ""
    @State private var hasSavedZaiAPIKey = false
    @State private var hookConfigurationStatus: AgentHookConfigurationStatus = .unknown
    @State private var activeTokenSaveAlert: TokenSaveAlert?
    private let keychainSaveAction: @Sendable (String, String) throws -> Void

    init(
        keychainSaveAction: @escaping @Sendable (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) {
        self.keychainSaveAction = keychainSaveAction
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            usageTab
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(SettingsTab.usage)

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            historyTab
                .tabItem { Label("History", systemImage: "calendar") }
                .tag(SettingsTab.history)
        }
        .frame(width: 450, height: 750)
        .onAppear {
            migrateLegacyClaudePlanIfNeeded()
            migrateLegacyCursorPlanIfNeeded()
            sanitizeNotificationSoundModeIfNeeded()
            migrateLegacyCopilotManualPATIfNeeded()
            loadAPIKeys()
            refreshHookConfigurationStatus()
        }
        .alert(item: $activeTokenSaveAlert) { alert in
            switch alert {
            case .saved:
                return Alert(
                    title: Text("Saved"),
                    dismissButton: .cancel(Text("OK"))
                )
            case .saveFailed(let message):
                return Alert(
                    title: Text("Save Failed"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
        #if AGENTBAR_NOTIFICATION_SOUNDS
        .sheet(isPresented: $showingSoundPackHelp) {
            SoundPackHelpSheet()
        }
        #endif
        .sheet(isPresented: $showingAgentSourcesHelp) {
            AgentSourcesHelpSheet()
        }
    }

    // MARK: - Usage Tab

    private var usageTab: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        try? LoginItemManager.setEnabled(newValue)
                    }

                Picker("Refresh interval", selection: $refreshInterval) {
                    Text("30s").tag(30.0)
                    Text("60s").tag(60.0)
                    Text("120s").tag(120.0)
                    Text("300s").tag(300.0)
                }
            }

            Section("Claude Code") {
                Toggle("Enabled", isOn: $claudeEnabled)
                    .onChange(of: claudeEnabled) { _ in
                        notifyLimitsChanged()
                    }

                Picker("Plan", selection: $claudePlan) {
                    ForEach(ClaudePlan.allCases, id: \.rawValue) { plan in
                        Text(plan.rawValue).tag(plan.rawValue)
                    }
                }
                .onChange(of: claudePlan) { _ in
                    notifyLimitsChanged()
                }

                Text("Usage is fetched from Anthropic OAuth API using Claude Code credentials")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI Codex") {
                Toggle("Enabled", isOn: $codexEnabled)
                    .onChange(of: codexEnabled) { _ in
                        notifyLimitsChanged()
                    }

                Picker("Plan", selection: $codexPlan) {
                    ForEach(CodexPlan.allCases, id: \.rawValue) { plan in
                        Text(plan.rawValue).tag(plan.rawValue)
                    }
                }
                .onChange(of: codexPlan) { newValue in
                    if let plan = CodexPlan(rawValue: newValue), plan != .custom {
                        codexFiveHourLimit = plan.fiveHourTokenLimit
                        codexWeeklyLimit = plan.weeklyTokenLimit
                    }
                    notifyLimitsChanged()
                }

                HStack {
                    Text("5h token limit:")
                    TextField("", value: $codexFiveHourLimit, format: .number)
                        .frame(width: 120)
                        .disabled(codexPlan != CodexPlan.custom.rawValue)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: codexFiveHourLimit) { _ in
                    if codexPlan == CodexPlan.custom.rawValue {
                        notifyLimitsChanged()
                    }
                }

                HStack {
                    Text("Weekly token limit:")
                    TextField("", value: $codexWeeklyLimit, format: .number)
                        .frame(width: 120)
                        .disabled(codexPlan != CodexPlan.custom.rawValue)
                    Text("tokens")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: codexWeeklyLimit) { _ in
                    if codexPlan == CodexPlan.custom.rawValue {
                        notifyLimitsChanged()
                    }
                }

                Text("Usage is derived from local session logs in ~/.codex/sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Google Gemini") {
                Toggle("Enabled", isOn: $geminiEnabled)
                    .onChange(of: geminiEnabled) { _ in
                        notifyLimitsChanged()
                    }

                HStack {
                    Text("Daily request limit:")
                    TextField("", value: $geminiDailyLimit, format: .number)
                        .frame(width: 120)
                    Text("requests")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: geminiDailyLimit) { _ in
                    notifyLimitsChanged()
                }

                Text("Usage is derived from local Gemini logs in ~/.gemini/tmp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GitHub Copilot") {
                Toggle("Enabled", isOn: $copilotEnabled)
                    .onChange(of: copilotEnabled) { _ in
                        notifyLimitsChanged()
                    }
                Text("Plan is auto-detected from GitHub API. Token is auto-read from gh CLI (gh auth token).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Manual PAT (optional fallback)") {
                    if hasSavedCopilotPAT {
                        Text("A manual PAT is already saved in Keychain")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        SecureField("ghp_...", text: $copilotPAT)
                            .frame(width: 200)
                        Button("Save") {
                            if saveCopilotPAT() {
                                notifyLimitsChanged()
                            }
                        }
                        .disabled(!Self.canSaveToken(copilotPAT))
                    }
                    Text("Only needed if gh CLI is not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Section("Cursor") {
                Toggle("Enabled", isOn: $cursorEnabled)
                    .onChange(of: cursorEnabled) { _ in
                        notifyLimitsChanged()
                    }

                Picker("Plan", selection: $cursorPlan) {
                    ForEach(CursorPlan.allCases, id: \.rawValue) { plan in
                        Text(plan.rawValue).tag(plan.rawValue)
                    }
                }
                .onChange(of: cursorPlan) { newValue in
                    if let plan = CursorPlan(rawValue: newValue), plan != .custom {
                        cursorMonthlyLimit = plan.monthlyUsageLimitUSD
                    }
                    notifyLimitsChanged()
                }

                HStack {
                    Text("Est. monthly usage:")
                    TextField("", value: $cursorMonthlyLimit, format: .number)
                        .frame(width: 120)
                        .disabled(cursorPlan != CursorPlan.custom.rawValue)
                    Text("USD")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: cursorMonthlyLimit) { _ in
                    if cursorPlan == CursorPlan.custom.rawValue {
                        notifyLimitsChanged()
                    }
                }

                Text("Credit-based pricing since June 2025. Usage is the dollar value of model usage in the current billing period; the included allotment is an estimate. Token is auto-read from Cursor's local database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Z.ai Coding Plan") {
                Toggle("Enabled", isOn: $zaiEnabled)
                    .onChange(of: zaiEnabled) { _ in
                        notifyLimitsChanged()
                    }
                if hasSavedZaiAPIKey {
                    Text("An API key is already saved in Keychain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("API Key:")
                    SecureField("API key", text: $zaiAPIKey)
                        .frame(width: 200)
                    Button("Save") {
                        if saveZaiAPIKey() {
                            notifyLimitsChanged()
                        }
                    }
                    .disabled(!Self.canSaveToken(zaiAPIKey))
                }
                Text("Plan and limits are auto-detected from Z.ai API")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Support") {
                Toggle("Hide Buy Me a Coffee button", isOn: $hideBuyMeACoffeeButton)
                Text("If you've already donated and the BMC button feels distracting, you can hide it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notifications Tab

    private var historyTab: some View {
        UsageHistoryTabView()
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section("Agent Notifications (Beta)") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Task completed", isOn: $notificationTaskCompletedEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationTaskCompletedEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Input required", isOn: $notificationInputRequiredEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationInputRequiredEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Show message preview", isOn: $notificationShowMessagePreview)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationShowMessagePreview) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Text("Preview shows the agent output text in the notification body when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!notificationsEnabled)

                Picker("Notification sound", selection: $notificationSoundMode) {
                    Text("System default").tag(NotificationSoundMode.system.rawValue)
                    Text("Mute").tag(NotificationSoundMode.mute.rawValue)
                }
                .disabled(!notificationsEnabled)
                .onChange(of: notificationSoundMode) { _ in
                    notifyNotificationsSettingsChanged()
                }

                Text("Mute keeps notifications visible while disabling all sounds, including the system default sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!notificationsEnabled)

                Button("Request Notification Permission") {
                    AgentNotifyNotificationService.requestAuthorizationPrompt()
                }
                .disabled(!notificationsEnabled)
            }

            #if AGENTBAR_NOTIFICATION_SOUNDS
            Section {
                Picker("Language", selection: $soundPackVM.selectedLanguage) {
                    Text("All").tag("")
                    ForEach(soundPackVM.availableLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .disabled(!notificationsEnabled)

                HStack {
                    Picker("Sound pack", selection: $soundPackVM.selectedPackName) {
                        Text("None").tag("")
                        ForEach(soundPackVM.filteredPacks) { pack in
                            HStack {
                                Text(pack.display_name)
                                if !pack.formattedSize.isEmpty {
                                    Text("(\(pack.formattedSize))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(pack.name)
                        }
                    }
                    .disabled(!notificationsEnabled || soundPackVM.isLoadingRegistry)
                    .onChange(of: soundPackVM.selectedPackName) { newValue in
                        soundPackVM.selectPack(newValue)
                    }

                    if soundPackVM.isLoadingRegistry {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await soundPackVM.loadRegistry(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(soundPackVM.isLoadingRegistry)
                }

                if soundPackVM.isDownloading {
                    ProgressView(value: soundPackVM.downloadProgress)
                        .progressViewStyle(.linear)
                }

                if let error = soundPackVM.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Test task.complete") {
                        _ = NotifySoundManager.shared.playTest(category: "task.complete")
                    }
                    .disabled(!notificationsEnabled || notificationSoundPackPath.isEmpty)

                    Button("Test input.required") {
                        _ = NotifySoundManager.shared.playTest(category: "input.required")
                    }
                    .disabled(!notificationsEnabled || notificationSoundPackPath.isEmpty)
                }

                agentSoundOverridesSection

                HStack {
                    Text("Volume:")
                    Slider(value: $notificationSoundVolume, in: 0...1, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.0f%%", notificationSoundVolume * 100))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!notificationsEnabled)
            } header: {
                HStack {
                    Text("Notification Sounds")
                    Spacer()
                    Button {
                        showingSoundPackHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif

            Section {
                Toggle("Codex file watcher", isOn: $notificationCodexEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationCodexEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("Claude hook", isOn: $notificationClaudeHookEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationClaudeHookEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                Toggle("OpenCode hook", isOn: $notificationOpencodeHookEventsEnabled)
                    .disabled(!notificationsEnabled)
                    .onChange(of: notificationOpencodeHookEventsEnabled) { _ in
                        notifyNotificationsSettingsChanged()
                    }

                HookConfigurationStatusRow(
                    title: "Codex notify hook",
                    status: hookConfigurationStatus.codex
                )

                HookConfigurationStatusRow(
                    title: "Claude hook command",
                    status: hookConfigurationStatus.claude
                )

                HStack {
                    Button("Re-check hook configuration") {
                        refreshHookConfigurationStatus()
                    }
                    Spacer()
                    if hookConfigurationStatus.checkedAt != .distantPast {
                        Text(hookConfigurationStatus.checkedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                }
            } header: {
                HStack {
                    Text("Agent Sources")
                    Spacer()
                    Button {
                        showingAgentSourcesHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        #if AGENTBAR_NOTIFICATION_SOUNDS
        .onAppear {
            Task { await soundPackVM.loadRegistry() }
        }
        #endif
    }

    #if AGENTBAR_NOTIFICATION_SOUNDS
    private var agentSoundOverridesSection: some View {
        DisclosureGroup("Agent Sound Overrides") {
            ForEach(SoundPackViewModel.overridableAgents, id: \.rawValue) { service in
                let account = service.keychainAccount
                let overrideValue = soundPackVM.agentOverrides[account] ?? ""
                let binding = Binding<String>(
                    get: { overrideValue },
                    set: { soundPackVM.selectAgentPack(service, name: $0) }
                )
                HStack {
                    Picker(service.rawValue, selection: binding) {
                        Text("Default").tag("")
                        Text("None").tag("__none__")
                        ForEach(soundPackVM.filteredPacks) { pack in
                            Text(pack.display_name).tag(pack.name)
                        }
                    }
                    .disabled(!notificationsEnabled)

                    Button {
                        _ = NotifySoundManager.shared.playTest(
                            category: "task.complete",
                            service: service
                        )
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!notificationsEnabled || overrideValue == "__none__")
                    .help("Test \(service.rawValue) sound")
                }
            }
        }
        .disabled(!notificationsEnabled)
    }
    #endif

    @discardableResult
    private func saveCopilotPAT() -> Bool {
        let outcome = saveTokenWithUIState(
            copilotPAT,
            account: ServiceType.copilot.keychainAccount,
            hasSavedToken: hasSavedCopilotPAT
        )
        hasSavedCopilotPAT = outcome.hasSavedToken
        if outcome.didSave {
            copilotManualPATEnabled = true
        }
        copilotPAT = outcome.tokenFieldValue
        return outcome.didSave
    }

    @discardableResult
    private func saveZaiAPIKey() -> Bool {
        let outcome = saveTokenWithUIState(
            zaiAPIKey,
            account: ServiceType.zai.keychainAccount,
            hasSavedToken: hasSavedZaiAPIKey
        )
        hasSavedZaiAPIKey = outcome.hasSavedToken
        zaiAPIKey = outcome.tokenFieldValue
        return outcome.didSave
    }

    private func saveTokenWithUIState(
        _ token: String,
        account: String,
        hasSavedToken: Bool
    ) -> TokenSaveUIOutcome {
        let outcome = Self.tokenSaveUIOutcome(
            currentToken: token,
            hasSavedToken: hasSavedToken,
            account: account,
            save: keychainSaveAction
        )
        if outcome.showSavedAlert {
            activeTokenSaveAlert = .saved
        } else if outcome.showSaveErrorAlert {
            activeTokenSaveAlert = .saveFailed(outcome.saveErrorMessage)
        } else {
            activeTokenSaveAlert = nil
        }
        return outcome
    }

    private func migrateLegacyClaudePlanIfNeeded() {
        if claudePlan == "Max" {
            claudePlan = ClaudePlan.max5x.rawValue
        }
        if ClaudePlan(rawValue: claudePlan) == nil {
            claudePlan = ClaudePlan.pro.rawValue
        }
    }

    private func migrateLegacyCursorPlanIfNeeded() {
        let resolvedPlan = CursorPlan.resolveAndMigrateStoredPlan()
        guard resolvedPlan.rawValue != cursorPlan else { return }

        cursorPlan = resolvedPlan.rawValue
        if resolvedPlan != .custom {
            cursorMonthlyLimit = resolvedPlan.monthlyUsageLimitUSD
        }
    }

    private func sanitizeNotificationSoundModeIfNeeded() {
        guard NotificationSoundMode(rawValue: notificationSoundMode) == nil else { return }
        notificationSoundMode = NotificationSoundMode.system.rawValue
    }

    private func migrateLegacyCopilotManualPATIfNeeded() {
        CopilotCredentialSettings.migrateLegacyManualPATIfNeeded(in: .standard)
        copilotManualPATEnabled = CopilotCredentialSettings.isManualPATEnabled(in: .standard)
    }

    private func loadAPIKeys() {
        if copilotManualPATEnabled {
            hasSavedCopilotPAT = KeychainManager.load(account: ServiceType.copilot.keychainAccount) != nil
        } else {
            hasSavedCopilotPAT = false
        }
        hasSavedZaiAPIKey = KeychainManager.load(account: ServiceType.zai.keychainAccount) != nil
        copilotPAT = ""
        zaiAPIKey = ""
    }

    private func refreshHookConfigurationStatus() {
        let checker = AgentHookConfigurationChecker()
        hookConfigurationStatus = checker.check()
    }

    private func notifyNotificationsSettingsChanged() {
        NotificationCenter.default.post(name: .notificationsSettingsChanged, object: nil)
    }

    private func notifyLimitsChanged() {
        NotificationCenter.default.post(name: .limitsChanged, object: nil)
    }

    struct TokenSaveUIOutcome: Equatable {
        let didSave: Bool
        let hasSavedToken: Bool
        let tokenFieldValue: String
        let showSavedAlert: Bool
        let showSaveErrorAlert: Bool
        let saveErrorMessage: String
    }

    enum TokenSaveAlert: Identifiable {
        case saved
        case saveFailed(String)

        var id: String {
            switch self {
            case .saved:
                return "saved"
            case .saveFailed(let message):
                return "saveFailed:\(message)"
            }
        }
    }

    enum SaveResult {
        case success
        case failure(String)
    }

    static func saveAPIKeyResult(
        _ key: String,
        account: String,
        save: (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) -> SaveResult {
        guard let sanitizedKey = sanitizedTokenForSaving(key) else {
            return .failure("Please enter a valid token before saving.")
        }
        do {
            try save(sanitizedKey, account)
            return .success
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return .failure("Failed to save token to Keychain.")
            }
            return .failure(message)
        }
    }

    static func tokenSaveUIOutcome(
        currentToken: String,
        hasSavedToken: Bool,
        account: String,
        save: (String, String) throws -> Void = { key, account in
            try KeychainManager.save(key: key, account: account)
        }
    ) -> TokenSaveUIOutcome {
        switch saveAPIKeyResult(currentToken, account: account, save: save) {
        case .success:
            return TokenSaveUIOutcome(
                didSave: true,
                hasSavedToken: true,
                tokenFieldValue: "",
                showSavedAlert: true,
                showSaveErrorAlert: false,
                saveErrorMessage: ""
            )
        case .failure(let message):
            return TokenSaveUIOutcome(
                didSave: false,
                hasSavedToken: hasSavedToken,
                tokenFieldValue: currentToken,
                showSavedAlert: false,
                showSaveErrorAlert: true,
                saveErrorMessage: message
            )
        }
    }

    static func sanitizedTokenForSaving(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveToken(trimmed) else { return nil }
        return trimmed
    }

    static func canSaveToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.allSatisfy { $0 == "*" }
    }
}

enum SettingsTab {
    case usage
    case history
    case notifications
}

#if AGENTBAR_NOTIFICATION_SOUNDS
private struct SoundPackHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notification Sounds (CESP)")
                .font(.headline)

            Text("Sound packs are fetched from the **PeonPing** registry and downloaded automatically when selected.")
                .font(.body)

            GroupBox("How It Works") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Select a sound pack from the dropdown")
                    Text("2. The pack is downloaded to **~/.openpeon/packs/**")
                    Text("3. Sounds play automatically for agent events")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Sound Categories") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**task.complete** — played when an agent finishes a task")
                    Text("**input.required** — played when an agent needs user input")
                    Text("Multiple files per category are rotated randomly without repeats.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Supported formats:** WAV, MP3, AIFF, M4A, CAF")
                    Text("**Registry:** peonping.github.io/registry")
                    Text("**Local storage:** ~/.openpeon/packs/")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
#endif

private struct AgentSourcesHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Sources")
                .font(.headline)

            Text("AgentBar receives agent events through the following sources.")
                .font(.body)

            GroupBox("Claude Hook") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receives events via Unix socket at **~/.agentbar/events.sock**.")
                    Text("Register the hook with **scripts/agentbar-hook.sh** in your Claude configuration.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Codex File Watcher") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monitors **~/.codex/sessions** for session file changes.")
                    Text("Fallback for users without hook configuration. Register **scripts/agentbar-codex-hook.sh** for socket-based delivery instead.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("OpenCode Hook") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receives OpenCode events via plugin and forwards to **~/.agentbar/events.sock**.")
                    Text("OpenCode permission/question prompts are normalized as **Input required** notifications.")
                    Text("Install with **scripts/install-agent-hooks.sh** (creates **~/.config/opencode/plugins/agentbar-notify.js**).")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Safe Hook Install") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run **scripts/install-agent-hooks.sh** to configure Codex/Claude/Gemini/OpenCode hooks.")
                    Text("The installer never overwrites configs without backup. Copies are saved under **~/.agentbar/backups/**.")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct HookConfigurationStatusRow: View {
    let title: String
    let status: AgentHookSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(status.isConfigured ? "Configured" : "Not configured")
                    .font(.caption)
                    .foregroundStyle(status.isConfigured ? .green : .secondary)
            }
            Text(status.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
