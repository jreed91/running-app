import SwiftUI
import AuthenticationServices

/// Connecting a Strava account, and whether finished runs go there by themselves.
///
/// The consent page runs in a web-authentication session rather than the Strava app, so
/// connecting works the same with or without it installed; the redirect back to
/// `stride://localhost/strava` is caught by the session, never by `StrideApp`.
struct StravaSettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var service: StravaService { container.stravaService }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                accountSection
                if service.isConnected {
                    uploadSection
                }
            }
            .padding(AppSpacing.lg)
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Strava")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Strava", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCOUNT")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(accountTitle)
                        .font(.bodyStrong)
                    Spacer()
                    if service.isConnected {
                        StrideIcon(name: .check, size: 16, color: .green, strokeWeight: 2)
                    }
                }

                Text(accountDetail)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)

                if service.isConfigured {
                    if service.isConnected {
                        Button(role: .destructive) {
                            Task { await disconnect() }
                        } label: {
                            Text("Disconnect")
                                .font(.dsFootnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.sm)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    } else {
                        Button {
                            Task { await connect() }
                        } label: {
                            Group {
                                if isWorking {
                                    ProgressView()
                                } else {
                                    Text("Connect with Strava")
                                }
                            }
                            .font(.dsFootnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.stravaOrange)
                        .disabled(isWorking)
                    }
                }
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var accountTitle: String {
        guard service.isConnected else {
            return String(localized: "Not connected", comment: "Strava connection state")
        }
        if let name = service.connection?.athleteName {
            return String(localized: "Connected as \(name)", comment: "Strava connection state with the athlete's name")
        }
        return String(localized: "Connected", comment: "Strava connection state")
    }

    private var accountDetail: String {
        if !service.isConfigured {
            return String(
                localized: "Strava isn't set up in this build.",
                comment: "Strava settings detail when the build has no Strava client ID"
            )
        }
        if service.isConnected {
            return String(
                localized: "Stride can upload your runs to Strava. It can't read your Strava activities or change anything else.",
                comment: "What a Strava connection lets Stride do"
            )
        }
        return String(
            localized: "Send the runs you record in Stride to your Strava feed, with their route, distance and time.",
            comment: "Strava settings detail before connecting"
        )
    }

    // MARK: - Uploads

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UPLOADS")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            Toggle(isOn: Bindable(service).uploadsAutomatically) {
                Text("Upload runs automatically")
                    .font(.bodyStrong)
            }
            .tint(.brand)
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))

            Text("Runs you record in Stride go to Strava as soon as you save them. Runs imported from Apple Health don't, because the watch or app that recorded them usually sends them already. You can send any run from its share menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
        }
    }

    // MARK: - Actions

    private func connect() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let (url, state) = try service.beginAuthorization()
            let callback = try await webAuthenticationSession.authenticate(
                using: url,
                callback: .customScheme(StravaAPI.callbackScheme),
                additionalHeaderFields: [:]
            )
            try await service.completeAuthorization(callbackURL: callback, expectedState: state)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the sheet is an answer, not a failure.
        } catch {
            AppLogger.log("Strava connect failed: \(error.localizedDescription)", label: "Strava", level: .error)
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() async {
        isWorking = true
        defer { isWorking = false }
        await service.disconnect()
    }
}

extension Color {
    /// Strava's brand orange (#FC4C02), for the Connect button its brand guidelines ask for.
    static let stravaOrange = Color(red: 252 / 255, green: 76 / 255, blue: 2 / 255)
}
