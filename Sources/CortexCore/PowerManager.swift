import Foundation
import IOKit.ps

public final class PowerManager: @unchecked Sendable {
    public static let shared = PowerManager()

    private let lock = NSLock()
    private var manualPause: Bool = false
    private var cancelGeneration: UInt64 = 0
    private var cancelledPaths: Set<String> = []

    private init() {}

    // MARK: - Manual Pause & Cancellation Control (works across GCD worker threads and Swift Tasks)

    public var isManuallyPaused: Bool {
        lock.withLock { manualPause }
    }

    public func setManuallyPaused(_ paused: Bool) {
        lock.withLock { manualPause = paused }
    }

    public var currentCancelGeneration: UInt64 {
        lock.withLock { cancelGeneration }
    }

    public func requestCancelAllIndexing() {
        lock.withLock {
            cancelGeneration &+= 1
            manualPause = false
            cancelledPaths.removeAll()
        }
    }

    public func requestCancelDocument(path: String) {
        let std = (path as NSString).standardizingPath
        lock.withLock { _ = cancelledPaths.insert(std) }
    }

    public func clearCancelledDocument(path: String) {
        let std = (path as NSString).standardizingPath
        lock.withLock { _ = cancelledPaths.remove(std) }
    }

    public func isCancelled(generation: UInt64? = nil, path: String? = nil) -> Bool {
        if Task.isCancelled { return true }
        let std = path.map { ($0 as NSString).standardizingPath }
        return lock.withLock {
            if let generation, cancelGeneration != generation { return true }
            if let std, cancelledPaths.contains(std) { return true }
            return false
        }
    }

    /// Prüft, ob der Mac aktuell rein auf internem Akku läuft (nicht am Ladekabel / Netzteil)
    public func isOnBattery() -> Bool {
        if ProcessInfo.processInfo.environment["CORTEXRAG_FAKE_BATTERY"] == "1" {
            return true
        }
        if let debugDir = ProcessInfo.processInfo.environment["CORTEXRAG_DEBUG_DIR"], !debugDir.isEmpty,
           FileManager.default.fileExists(atPath: (debugDir as NSString).appendingPathComponent("fake-battery")) {
            return true
        }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                if state == (kIOPSBatteryPowerValue as String) {
                    return true
                }
            }
        }
        return false
    }

    /// Prüft, ob der macOS Stromsparmodus (Low Power Mode) aktiv ist
    public func isLowPowerMode() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Liefert das aktuell wirksame Indizierungs-Tempo (am Netzteil: `throttlingMode`, auf Akku: `batteryThrottlingMode`).
    public func activeThrottlingMode(settings: CortexSettings = CortexSettingsManager.shared.settings) -> IndexingThrottleMode {
        isOnBattery() ? settings.batteryThrottlingMode : settings.throttlingMode
    }

    /// Gibt Auskunft, ob eine rechenintensive Indizierung basierend auf den Benutzereinstellungen gestartet werden darf
    public func canRunIndexing(settings: CortexSettings = CortexSettingsManager.shared.settings) -> (canRun: Bool, reason: String?) {
        if isManuallyPaused {
            return (false, "Pausiert: Manuell pausiert.")
        }
        if settings.pauseOnLowPowerMode && isLowPowerMode() {
            return (false, "Pausiert: macOS Stromsparmodus (Low Power Mode) ist aktiv.")
        }
        if settings.indexOnlyOnACPower && isOnBattery() {
            return (false, "Pausiert: Mac läuft auf Akku (Einstellung: 'Auf Akku pausieren').")
        }
        return (true, nil)
    }

    /// Blocks while indexing is not allowed (manual pause / battery / Low Power Mode, according to the *current* settings)
    /// and returns as soon as it is allowed again. Throws `CancellationError` within ~120 ms when cancelled.
    public func waitUntilIndexingAllowed(
        generation: UInt64? = nil,
        path: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        var lastReportedReason: String?
        while true {
            if isCancelled(generation: generation, path: path) { throw CancellationError() }
            let (ok, reason) = canRunIndexing(settings: CortexSettingsManager.shared.settings)
            if ok { break }
            let msg = reason ?? "Pausiert"
            if lastReportedReason != msg {
                progress?(msg)
                lastReportedReason = msg
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        if lastReportedReason != nil { progress?("Fortgesetzt") }
    }

    /// Async variant for actor code: waits without blocking the actor (searches keep working during a pause).
    public func waitUntilIndexingAllowedAsync(
        generation: UInt64? = nil,
        path: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var lastReportedReason: String?
        while true {
            if isCancelled(generation: generation, path: path) { throw CancellationError() }
            let (ok, reason) = canRunIndexing(settings: CortexSettingsManager.shared.settings)
            if ok { break }
            let msg = reason ?? "Pausiert"
            if lastReportedReason != msg {
                progress?(msg)
                lastReportedReason = msg
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        if lastReportedReason != nil { progress?("Fortgesetzt") }
    }

    /// Pause between pages from the *current* effective throttling setting (AC vs. battery; changes apply immediately).
    public func throttlePause(generation: UInt64? = nil, path: String? = nil) {
        let ns = activeThrottlingMode().delayNanoseconds
        guard ns > 0 else { return }
        let totalUs = min(ns / 1000, UInt64(UInt32.max))
        let sliceUs: UInt64 = 30_000 // 30 ms slices so cancel reacts immediately
        var waited: UInt64 = 0
        while waited < totalUs {
            if isCancelled(generation: generation, path: path) { return }
            let step = min(sliceUs, totalUs - waited)
            usleep(useconds_t(step))
            waited += step
        }
    }

    /// Pause after an embedding step that took `seconds`: compute time × duty factor of the active mode (AC or battery),
    /// at least the mode's fixed delay, at most 3 s. Limits average GPU load – and with it power draw – on battery.
    public func applyDutyCycle(afterWork seconds: Double) async {
        let mode = activeThrottlingMode()
        guard mode != .turbo else { return }
        let pause = min(3.0, max(Double(mode.delayNanoseconds) / 1e9, seconds * mode.dutyFactor))
        try? await Task.sleep(for: .seconds(pause))
    }

    /// Wartet entsprechend des gewählten Throttling-Modus, um die CPU/GPU-Temperatur und den Akkuverbrauch zu schonen
    public func applyThrottlingDelay(mode: IndexingThrottleMode) async {
        let ns = mode.delayNanoseconds
        if ns > 0 {
            try? await Task.sleep(nanoseconds: ns)
        }
    }
}
