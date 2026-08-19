import Foundation

/// Simulator and jailbreak signals for the install beacon — the iOS twin of
/// `DeviceIntegrity.kt`.
///
/// ## Reports signals, never a verdict
///
/// The classification happens on the server (`services/integrity.py`), for the
/// same reason `require_signed_beacons` is server-side: an app build lives on
/// real devices for years, so a threshold baked in here could only be retuned at
/// the speed of App Review and user updates. Sending evidence rather than a
/// conclusion means the rule can change on a deploy, and old installs can be
/// reinterpreted.
///
/// ## Honest ceiling
///
/// This is a self-report from a device that may be the adversary: a jailbroken
/// device can hook `stat` and make every one of these checks return clean, and
/// the tooling to do exactly that is off-the-shelf. It catches the careless and
/// the incidental — mostly the customer's own QA and CI, and separating those
/// out is most of the value. It is not proof and must never be called proof.
///
/// ## Deliberately not included
///
/// `canOpenURL("cydia://")` is a classic jailbreak check and is omitted: it
/// requires declaring the scheme in `LSApplicationQueriesSchemes`, which puts a
/// jailbreak-detection string in the host app's Info.plist — someone else's
/// binary, for our diagnostic. Not our call to make.
enum DeviceIntegrity {

    /// Artefacts that only exist on a jailbroken device.
    private static let jailbreakPaths: [(path: String, signal: String)] = [
        ("/Applications/Cydia.app", "cydia"),
        ("/Applications/Sileo.app", "cydia"),
        ("/Library/MobileSubstrate/MobileSubstrate.dylib", "mobilesubstrate"),
        ("/usr/lib/libsubstrate.dylib", "mobilesubstrate"),
        ("/var/jb", "mobilesubstrate"), // rootless jailbreaks
        ("/etc/apt", "apt"),
        ("/private/var/lib/apt", "apt"),
        ("/bin/bash", "shell"),
        ("/usr/sbin/sshd", "shell"),
    ]

    /// The signals that fired, as short stable names the server knows. Empty on
    /// an ordinary device, so the field is usually absent from the beacon.
    static func signals() -> [String] {
        var found: [String] = []

        #if targetEnvironment(simulator)
        // Conclusive and free — compiled for the simulator, so it IS one.
        found.append("simulator")
        #endif

        // A sandboxed app cannot see most of the filesystem, so a false here is
        // "cannot tell" as much as "absent" — which is exactly why these are
        // signals to be weighed server-side rather than a verdict.
        let manager = FileManager.default
        for entry in jailbreakPaths where manager.fileExists(atPath: entry.path) {
            if !found.contains(entry.signal) { found.append(entry.signal) }
        }

        if canWriteOutsideSandbox() { found.append("sandbox_write") }
        return found
    }

    /// Writing outside the app container is impossible under a working sandbox,
    /// so success is the single strongest signal available on iOS.
    private static func canWriteOutsideSandbox() -> Bool {
        #if targetEnvironment(simulator)
        // The simulator has no real sandbox, so this would fire for every
        // developer on every run and tell us nothing we don't already know from
        // the compile-time check above.
        return false
        #else
        let probe = "/private/roas_sandbox_probe"
        do {
            try "x".write(toFile: probe, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false // the expected outcome on a healthy device
        }
        #endif
    }
}
