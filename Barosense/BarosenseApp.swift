import SwiftUI
import UserNotifications

@main
struct BarosenseApp: App {

    /// Composition root for HealthKit ingest. Profile / tag stores live in `AppServices`;
    /// the domain layer stays constructible from a test with doubles either way.
    private let ingest: HealthIngestController

    /// Composition root for barometer collection. The phone is the device with the sensor;
    /// the watch is a second screen onto it — see `PressureCollectionController` for why.
    private let pressure: PressureCollectionController

    /// The two sensor logs, kept here as well as inside the controllers. Settings needs
    /// them to erase the history, and re-opening the same store file a second time from
    /// there would be a second container over one SQLite file.
    private let healthLog: any HealthSampleStore
    private let pressureLog: any PressureSampleStore

    /// The epoch table, on the same container as the barometer log. Held here for the reason
    /// the two logs are: an erase has to reach it, and re-opening the same store file from
    /// Settings would be a second container over one SQLite file.
    private let locationEpochs: any PressureLocationEpochStore

    /// The forecast archive, and the controller that fills it. Both here for the reason the
    /// barometer's controller is: the background task closure below has to reach it, and that
    /// closure is declared on the scene.
    private let weatherArchive: any WeatherForecastStore
    private let weather: WeatherForecastController

    /// The forward half of the chart, and the same object the refresh controller reads its
    /// feature row off. **One instance**: it caches the station-to-MSLP offset and the local
    /// fit, and two of them would each pay for their own and could disagree about which curve
    /// the app is showing.
    private let forecast: PressureForecastReader

    /// Where a tapped notification asks to go, and the delegate that records it.
    ///
    /// Both are held here for the same reason the ingest observers are started here: iOS
    /// delivers a tap that launched the app as soon as launching finishes, so the delegate has
    /// to be in place before that. `UNUserNotificationCenter.delegate` is also a weak reference,
    /// which makes holding the responder the difference between it working and it being
    /// deallocated on the next line.
    private let router = NotificationRouter()
    private let notificationResponder: NotificationResponder

    init() {
        let responder = NotificationResponder(router: router)
        UNUserNotificationCenter.current().delegate = responder
        notificationResponder = responder

        let log: any HealthSampleStore
        do {
            log = try SwiftDataHealthSampleStore.makePersistent()
        } catch {
            // A store that cannot open must not take the app down with it. Fall back to
            // the in-memory double so the Now row still works; the training log simply
            // does not survive this launch. Surface this in Settings later — do not
            // crash on first paint.
            //
            // Logged rather than swallowed: the Health row re-reads HealthKit on every
            // screen load, so this failure is invisible on screen and shows up only as a
            // training log that never grows.
            BarosenseLog.persistence.error(
                "health store unavailable, falling back to memory: \(String(describing: error), privacy: .public)"
            )
            log = InMemoryHealthSampleStore()
        }

        let recorder = HealthSampleRecorder(reader: HealthKitDataReader(), log: log)
        let changeObserver: any HealthChangeObserving = HealthBackgroundDelivery.isEnabled
            ? HealthKitChangeObserver()
            : NoOpHealthChangeObserver()

        healthLog = log
        ingest = HealthIngestController(recorder: recorder, changeObserver: changeObserver)
        // Observers must exist before HealthKit delivers a background wake.
        ingest.start()

        let pressureLog: any PressureSampleStore
        let locationEpochs: any PressureLocationEpochStore
        do {
            // One container, two actors over it. The samples reference the epochs, so opening
            // them separately is the failure `BarosenseModelContainer` warns about for
            // check-ins and the tag vocabulary, on a different pair of tables.
            let container = try SwiftDataPressureSampleStore.makeContainer(inMemory: false)
            pressureLog = SwiftDataPressureSampleStore(modelContainer: container)
            locationEpochs = SwiftDataPressureLocationEpochStore(modelContainer: container)
        } catch {
            // Worse here than the Health fallback above. This is now the *only* copy of the
            // barometer history — no other device keeps one — so a failed open costs the
            // training log everything recorded before the next successful launch, and the
            // chart reads as if the sensor had never run. Hence the log line.
            BarosenseLog.persistence.error(
                "pressure store unavailable, falling back to memory: \(String(describing: error), privacy: .public)"
            )
            pressureLog = InMemoryPressureSampleStore()
            locationEpochs = InMemoryPressureLocationEpochStore()
        }

        self.pressureLog = pressureLog
        self.locationEpochs = locationEpochs

        let weatherArchive: any WeatherForecastStore
        do {
            weatherArchive = try SwiftDataWeatherForecastStore.makePersistent()
        } catch {
            // Less costly than the barometer's fallback: these rows can be fetched again on
            // the next slot. What is lost is the offset calibration's history and the realised
            // skill record, both of which rebuild themselves over days rather than being
            // irreplaceable.
            BarosenseLog.persistence.error(
                "weather archive unavailable, falling back to memory: \(String(describing: error), privacy: .public)"
            )
            weatherArchive = InMemoryWeatherForecastStore()
        }
        self.weatherArchive = weatherArchive

        let forecast = PressureForecastReader(archive: weatherArchive,
                                              samples: pressureLog,
                                              epochs: locationEpochs)
        self.forecast = forecast

        weather = WeatherForecastController(
            refresher: WeatherForecastRefresher(
                // The one outbound network path in the app. Everything that decides whether it
                // is used sits in the refresher, in `Shared/`, where a test can reach it.
                provider: WeatherKitForecastProvider(),
                store: weatherArchive,
                epochs: locationEpochs,
                access: CoreLocationAccessReporter(),
                preferences: UserDefaultsWeatherKitPreferenceStore()
            ),
            // The §2.2 feature row and the realised-skill comparison are read off this after
            // every request that lands — see `WeatherForecastController.refresh(asOf:)`.
            forecast: forecast,
            // Read for the end of the most recent sleep session, which moves the first request
            // slot of the day. Nothing health-derived reaches the payload — see
            // `WeatherForecastController.wakeTime`.
            healthLog: log
        )

        let link = WatchConnectivityPressureLink()
        link?.activate()

        pressure = PressureCollectionController(
            recorder: PressureSampleRecorder(source: CoreMotionPressureSource(), log: pressureLog),
            display: link ?? NoOpPressureDisplayLink(),
            // The only place CoreLocation is wired in. It resolves an epoch on a foreground
            // activation and reads the stored one on a background wake — see
            // `LocationEpochRecorder`.
            locationEpochs: LocationEpochRecorder(access: CoreLocationAccessReporter(),
                                                  fixes: CoreLocationFixProvider(),
                                                  namer: CLGeocoderPlaceNamer(),
                                                  store: locationEpochs)
        )
        // Takes the launch reading. The background chain is armed from the scene below,
        // not here — see `PressureCollectionController.armBackgroundRefresh`.
        pressure.start()
    }

    var body: some Scene {
        let pressure = pressure
        let weather = weather
        let forecast = forecast

        return WindowGroup {
            AppRootView(ingest: ingest,
                        pressure: pressure,
                        weather: weather,
                        forecast: forecast,
                        healthLog: healthLog,
                        pressureLog: pressureLog,
                        locationEpochs: locationEpochs,
                        weatherArchive: weatherArchive,
                        router: router)
                // The earliest point at which `.backgroundTask` below has registered the
                // identifier. Submitting before that raises an uncatchable ObjC exception.
                .task { pressure.armBackgroundRefresh() }
        }
        // The system holds the app awake for the length of this closure and suspends it the
        // moment the closure returns, so the reading and the durable write have to finish
        // inside it. `handleBackgroundRefresh` also re-arms the next wake.
        //
        // The identifier must match `BGTaskSchedulerPermittedIdentifiers` in the generated
        // Info.plist (`project.yml`); a mismatch fails at submit time, not here.
        .backgroundTask(.appRefresh(PressureSamplingPolicy.backgroundRefreshIdentifier)) {
            await pressure.handleBackgroundRefresh()
            // Rides the barometer's wake rather than asking for one of its own — there is
            // exactly one background identifier in this app and this feature adds none.
            // Usually a no-op: the slot budget decides, and most wakes have nothing due.
            await weather.handleBackgroundRefresh()
        }
    }
}
