import CoreMotion
import Foundation

/// The only place `CMAltimeter` is touched.
///
/// Everything below the `PressureSource` protocol is CoreMotion-shaped; everything above
/// it is `Pressure`. `CMAltitudeData.pressure` arrives in **kPa** and is converted here and
/// only here, the way HealthKit units are converted in `HealthKitDataReader` — a kPa value
/// that escaped this file would be a silent 10× error nothing downstream could catch.
///
/// An `actor` rather than a struct: `CMAltimeter` is a mutable reference type with a
/// start/stop lifecycle, and two overlapping reads would fight over the same sensor
/// session. Serialising here means a caller cannot create that race by accident.
///
/// ## What this deliberately does not do
///
/// `startRelativeAltitudeUpdates` also reports relative altitude, and it is tempting to use
/// it to separate an elevator ride from weather. It cannot: that altitude is *derived from
/// pressure*, so the correction is circular (`.claude/context/ml-spec.md` §3). Altitude
/// rejection happens at feature time, on the stored series, and never here.
actor CoreMotionPressureSource: PressureSource {

    private let altimeter = CMAltimeter()

    /// How long to wait for the first callback before giving up.
    ///
    /// The sensor normally reports at roughly 1 Hz once started, so a healthy read
    /// finishes in about a second. Five is generous enough to survive a slow start and
    /// short enough that a watch background-refresh wake is not spent waiting on a sensor
    /// that is never going to answer.
    private let timeout: Duration

    /// Dedicated queue for the CoreMotion callback. Kept off `.main`: the handler fires
    /// repeatedly while the sensor is running, and none of that work belongs on the queue
    /// that is drawing.
    private let callbackQueue: OperationQueue

    init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout

        let queue = OperationQueue()
        queue.name = "com.barosense.barometer"
        queue.maxConcurrentOperationCount = 1
        self.callbackQueue = queue
    }

    nonisolated var isAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable()
    }

    func currentPressure() async throws -> Pressure {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            throw PressureSourceError.barometerUnavailable
        }

        // `.notDetermined` is not a refusal — starting updates is what raises the Motion &
        // Fitness prompt in the first place, so only a settled "no" stops us here.
        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted:
            throw PressureSourceError.notAuthorized
        default:
            break
        }

        return Pressure(kilopascals: try await firstReadingKilopascals())
    }

    /// Starts the sensor, returns its first reading, and stops it again.
    ///
    /// The callback API is wrapped in an `AsyncStream` rather than a bare continuation
    /// because the handler fires *repeatedly* — a continuation would be resumed a second
    /// time and trap. Only a `Double` is yielded out of the handler: `CMAltitudeData` is
    /// not `Sendable`, and unwrapping it on the callback queue keeps it from crossing an
    /// isolation boundary at all.
    private func firstReadingKilopascals() async throws -> Double {
        let (readings, continuation) = AsyncStream.makeStream(of: Double.self)

        altimeter.startRelativeAltitudeUpdates(to: callbackQueue) { data, _ in
            guard let data else { return }
            continuation.yield(data.pressure.doubleValue)
        }

        // The sensor stops on every exit path, including cancellation. Leaving it running
        // is the one bug in this file that would actually cost battery.
        defer {
            altimeter.stopRelativeAltitudeUpdates()
            continuation.finish()
        }

        let deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer { deadline.cancel() }

        for await kilopascals in readings {
            return kilopascals
        }

        // The stream finished without yielding: the deadline won, or the task was
        // cancelled before the sensor answered.
        try Task.checkCancellation()
        throw PressureSourceError.timedOut
    }
}
