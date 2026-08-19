import Foundation
// `os(iOS)`, not `canImport(CoreLocation)`: CoreLocation imports fine on macOS
// too, but the INSTANCE `authorizationStatus` property this reads is macOS 11+
// while `Package.swift` declares macOS 10.15 so the hash-parity tests can run
// on a Mac host without a simulator. A canImport guard would compile on iOS and
// break `swift test`. Mac Catalyst reports `os(iOS)` and is included, which is
// correct — CoreLocation behaves the same there.
#if os(iOS)
import CoreLocation
#endif

/// Coarse device location — **only when the host app already holds a location
/// permission for its own reasons.** The iOS twin of `DeviceLocation.kt`.
///
/// ## This SDK never asks for location, and must never start
///
/// Nothing here calls `requestWhenInUseAuthorization()` or
/// `requestAlwaysAuthorization()`, and adding one would be a serious mistake
/// rather than a feature. On iOS the prompt is gated on a usage string in the
/// **host app's** Info.plist, so an SDK that asked would either crash the app
/// outright (no string) or make an app the user trusted for other reasons
/// suddenly demand location for an attribution library the developer never
/// signed up for. An attribution SDK must not make that decision on a
/// customer's behalf — the same rule `DeviceLocation.kt` states about Android
/// manifest merging.
///
/// So this reads location only where it is already free: the host app declared
/// the permission and the user already granted it, for the app's own features.
/// On every other app `read()` returns nil and nothing happens — no prompt, no
/// policy exposure, no behaviour change. Linking CoreLocation without ever
/// requesting authorization is not itself an App Review concern; requesting it
/// without a usage string is, and we never do.
///
/// ## Why last-known, and why rounded
///
/// `CLLocationManager.location` is the cached fix — the direct analogue of
/// Android's `getLastKnownLocation`. It never powers up the GPS, costs no
/// battery, and returns immediately, which is what a value that merely
/// decorates an install beacon deserves. Starting live updates would put a
/// hardware radio on the critical path of reporting an install.
///
/// The result is rounded to two decimals (~1.1 km) **before it leaves the
/// device**, not server-side, so the precise value never travels at all. A geo
/// dashboard renders cities; metre-accurate coordinates would collect a far
/// more sensitive value than the use case needs.
///
/// ## This is a bonus, never the primary geo
///
/// Coverage is whatever fraction of a customer's users happen to use an app
/// that already has location — a self-selected minority. `services/geo.py`
/// resolves country/region/city from the IP for 100% of traffic with no
/// permission at all, and that is what a dashboard should be built on.
enum DeviceLocation {

    /// How stale a cached fix may be and still be worth reporting. A week-old
    /// position describes a trip, not an install.
    private static let maxAge: TimeInterval = 24 * 60 * 60

    #if os(iOS)
    /// Held across reads so the manager is created once. CoreLocation asks that
    /// a manager be created on a thread with an active run loop, which is why
    /// every caller of `read()` is on the main thread (see
    /// `DeviceContext.refreshVolatile`).
    private static var manager: CLLocationManager?
    #endif

    /// `(lat, lon)` rounded to ~1.1km, or nil when the host app holds no
    /// location permission, nothing is cached, or the fix is too old.
    ///
    /// **Call on the main thread.**
    static func read() -> (Double, Double)? {
        #if os(iOS)
        let manager: CLLocationManager
        if let existing = DeviceLocation.manager {
            manager = existing
        } else {
            manager = CLLocationManager()
            DeviceLocation.manager = manager
        }
        // The INSTANCE property, not the deprecated `CLLocationManager.authorizationStatus()`
        // class method — this SDK's floor is iOS 14, which is exactly where the
        // instance property landed and the class method began warning.
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            // .notDetermined is the ordinary case for an app that never asked,
            // and it stays that way: we do not prompt.
            return nil
        }
        guard let fix = manager.location else { return nil }
        guard Date().timeIntervalSince(fix.timestamp) <= maxAge else { return nil }
        let coordinate = fix.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return (round2(coordinate.latitude), round2(coordinate.longitude))
        #else
        return nil
        #endif
    }

    /// Two decimals ≈ 1.1 km. Deliberately lossy — see the type doc.
    private static func round2(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}
