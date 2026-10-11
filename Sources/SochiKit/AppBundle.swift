import CryptoKit
import Foundation

/// Ground truth about a built `.app`, read from the bundle itself rather than from build settings.
public enum AppBundle {
    /// Confirms the bundle on disk is the one we mean to install: it exists, has the expected
    /// bundle identifier, and was built for the destination's platform (never a simulator build on a device).
    public static func verify(_ product: AppProduct, for destination: Destination) throws {
        let info = try infoPlist(product.appURL)
        let bundleID = info["CFBundleIdentifier"] as? String
        guard bundleID == product.bundleIdentifier else {
            throw SochiError.productMismatch("\(product.appURL.lastPathComponent) has bundle ID \(bundleID ?? "none"), expected \(product.bundleIdentifier)")
        }
        let platform = info["DTPlatformName"] as? String
        guard platform == destination.sdkPlatformName else {
            throw SochiError.productMismatch("\(product.appURL.lastPathComponent) was built for \(platform ?? "an unknown platform"), not \(destination.sdkPlatformName)")
        }
    }

    /// A content hash covering the whole bundle: the main executable plus the code signature's resource
    /// manifest, which itself hashes every other file (including nested frameworks and the debug dylib).
    /// Returns nil for unsigned bundles, which means "unknown" and forces an install.
    public static func fingerprint(_ appURL: URL) -> String? {
        guard let info = try? infoPlist(appURL),
              let executable = info["CFBundleExecutable"] as? String,
              let binary = try? Data(contentsOf: appURL.appendingPathComponent(executable), options: .alwaysMapped),
              let resources = try? Data(contentsOf: appURL.appendingPathComponent("_CodeSignature/CodeResources"))
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: binary)
        hasher.update(data: resources)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func infoPlist(_ appURL: URL) throws -> [String: Any] {
        let url = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw SochiError.productMismatch("no readable Info.plist at \(url.path)") }
        return plist
    }
}
