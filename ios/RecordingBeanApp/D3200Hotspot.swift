#if os(iOS)
import Foundation
#if RECORDINGBEAN_AUTOMATIC_HOTSPOT
import NetworkExtension
#endif
import Security

/// One temporary hotspot association per download batch.
final class D3200Hotspot {
    let ssid: String
    private let password: String

    init() throws {
        var random = Data(count: 16)
        let result = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw URLError(.cannotCreateFile) }
        let hex = random.map { String(format: "%02x", $0) }.joined()
        ssid = "Bean-" + String(hex.prefix(8))
        password = String(hex.dropFirst(8))
    }

    var credentials: Data {
        let name = Data(ssid.utf8), pass = Data(password.utf8)
        return Data([UInt8(name.count)]) + name + Data([UInt8(pass.count)]) + pass
    }

    func join(manually: (String, String) async throws -> Void) async throws {
        #if RECORDINGBEAN_AUTOMATIC_HOTSPOT
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        try await NEHotspotConfigurationManager.shared.apply(configuration)
        // Applying the configuration precedes association and IP routing. The
        // Wi-Fi-only pinned socket waits until the fixed local endpoint is reachable.
        #else
        try await manually(ssid, password)
        #endif
    }

    func leave() {
        #if RECORDINGBEAN_AUTOMATIC_HOTSPOT
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
    }
}
#endif
