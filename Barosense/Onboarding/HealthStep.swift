import SwiftUI

/// O5 · Apple Health and the barometer (Figma `7:543`).
///
/// The step where the app asks for what it reads, and the only screen in the flow that
/// raises a system prompt. "Connect" runs both requests in order — the Health sheet for
/// `HealthKitReadSet`, then the Motion & Fitness alert `CMAltimeter` raises when the
/// barometer is first started — and "Skip" runs neither. See
/// `OnboardingModel.requestHealthAccess()`.
///
/// ## Why the rows are switches now
///
/// They used to be three bullet points: a static list of what the app reads, drawn the same
/// whether or not anything had been granted. That made the step unable to report its own
/// outcome. Both prompts went out behind one button, and a user who declined Motion & Fitness
/// — or who never really saw that second alert, because it lands while the Health sheet is
/// still sliding away — walked into an app whose pressure chart would never fill, with
/// nothing anywhere having said so. The bug is the missing readback, not the missing prompt.
///
/// The barometer is the one permission in this app a switch can honestly reflect:
/// `CMAltimeter.authorizationStatus()` reports a refusal, so "off" is a fact and the caption
/// can name the one place that undoes it. Apple Health cannot — iOS never reveals a read
/// grant (`.claude/skills/healthkit_permissions/SKILL.md`) — so its switch reports what a
/// probe read actually returned and its captions never say "denied", exactly as the Settings
/// screen's copy does not.
///
/// The rows name exactly what the Health sheet will list, and nothing beyond it. They used
/// to promise activity, which is not in the read set and so never appears on the sheet:
/// a step describing reads the app does not make is the consumer-first rule of
/// `.claude/skills/healthkit_permissions/SKILL.md` read backwards, and the kind of
/// mismatch App Review asks about.
struct HealthStep: View {

    @Bindable var model: OnboardingModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Connect",
            // Dimmed while the two sheets are up. They are modal, so this is not what stops
            // a second tap — `requestHealthAccess` guards that itself — it is what says the
            // step is mid-request when the first sheet is dismissed and the second has not
            // yet drawn.
            isActionEnabled: !model.isRequestingAccess,
            action: connect,
            skipTitle: "Skip",
            skip: model.skipHealthAccess
        ) {
            VStack(spacing: 24) {
                OnboardingHeader(
                    title: "Connect your data",
                    subtitle: "Sleep, heart rate and pressure are read for you — no typing",
                    titleFont: Typography.onboardingTitleCompact,
                    alignment: .center
                )

                VStack(spacing: 10) {
                    PermissionToggleRow(title: "Apple Health",
                                        caption: healthCaption,
                                        isOn: model.healthAccess.isFullyReadable,
                                        isEnabled: model.healthAccess != .unavailable
                                            && !model.isRequestingAccess,
                                        tap: tapHealth)

                    PermissionToggleRow(title: "Pressure from this device's barometer",
                                        caption: barometerCaption,
                                        isOn: model.barometerAccess.isCollecting,
                                        isEnabled: model.barometerAccess.isInteractive
                                            && !model.isRequestingAccess,
                                        tap: tapBarometer)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await model.refreshAccessStates() }
        // The only way out of a refusal is a trip to another app, and this step is what sent
        // the user on it. Without this the switch would still be showing the pre-grant state
        // when they came back — the same reason the Settings screen re-reads on activation.
        // One `CMAltimeter` status read plus one Health probe, in the foreground, on a return
        // the user initiated.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refreshAccessStates() }
        }
    }

    /// Never says "denied", for the reason the Settings screen's does not: iOS does not reveal
    /// a read refusal, and an empty Health store looks identical from here. Each line states
    /// what was observed and names the one place that can settle it.
    private var healthCaption: LocalizedStringKey? {
        switch model.healthAccess {
        case .unavailable:
            "Health data isn't available on this device."
        case .notRequested:
            "Fills in sleep, resting heart rate and blood oxygen for you."
        case .requested where model.healthAccess.isFullyReadable:
            nil
        case .requested:
            "Barosense can't read everything yet. Open Health to check what it may read."
        }
    }

    /// This one *can* say the user declined, because CoreMotion actually reports it.
    private var barometerCaption: LocalizedStringKey? {
        switch model.barometerAccess {
        case .unavailable:
            "This device has no barometer. Barosense will use the forecast for your area instead."
        case .notRequested:
            "Lets Barosense record the pressure around you as it changes."
        case .granted:
            nil
        case .denied:
            "Motion & Fitness is off for Barosense. Turn it on in iOS Settings to record pressure."
        }
    }

    private func tapHealth() {
        Task {
            if await model.toggleHealthAccess() == .needsHealthApp {
                HealthAppLink.open()
            }
        }
    }

    private func tapBarometer() {
        Task {
            if await model.toggleBarometerAccess() == .needsSystemSettings {
                MotionSettingsLink.open()
            }
        }
    }

    /// The `Task` the model deliberately does not start for itself.
    ///
    /// `requestHealthAccess()` is `async` so a test can await the order the two prompts go
    /// out in, which leaves someone to bridge it to a `() -> Void` button action, and the
    /// view is that someone. A method rather than a closure literal in the call above, for
    /// the same reason every other step passes one: the scaffold already takes a trailing
    /// closure for its content, and a second closure beside it reads as two bodies.
    private func connect() {
        Task { await model.requestHealthAccess() }
    }
}

/// One permission, as a row with a switch and a line saying what its state means.
///
/// Not `SettingsToggleRow`: that one lives inside a `SettingsCard` and takes its edges from it,
/// while onboarding draws each row on its own rounded surface. What the two do share is
/// `BarosenseToggleStyle`, so the switch is the same object in both places and VoiceOver still
/// announces a switch with an on/off value.
///
/// The switch is never written to directly. Every "off" here has more than one cause and each
/// needs a different action — raise a sheet, open Health, open iOS Settings — so the tap is
/// interpreted by the model and the displayed value comes back from a re-read. That is what
/// keeps the control from showing a state the system disagrees with, including the case where
/// the user answers a sheet with a refusal and the switch has to fall straight back to off.
private struct PermissionToggleRow: View {

    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    let isOn: Bool
    var isEnabled: Bool = true
    let tap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding) {
                Text(title)
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(BarosenseToggleStyle())
            .disabled(!isEnabled)

            if let caption {
                Text(caption)
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.placeholder)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }

    /// Reads the observed state and discards what the switch tried to set, which is the whole
    /// point — see the note on the type.
    private var binding: Binding<Bool> {
        Binding(get: { isOn }, set: { _ in tap() })
    }
}

#Preview {
    HealthStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                      tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                      sensorAccess: NoOpSensorAccess(),
                                      onFinished: {}))
}
