import Foundation
import Photos

// Standalone CLI probe. Prefer Settings > Open Diagnostics… > Export Historical Metadata Audit…
// inside Photo Curator: a bare `swift` process is a different TCC client and usually never prompts.
guard CommandLine.arguments.count >= 2 else {
    fputs("""
    Usage: swift Tools/audit_historical_metadata.swift /private/output.json [--request-access]

    This CLI binary is not Photo Curator. macOS Photos prompts and grants belong to an app
    bundle with NSPhotoLibraryUsageDescription. Use Photo Curator → Settings → Open
    Diagnostics… → Export Historical Metadata Audit… instead.

    --request-access only helps when status is still notDetermined for this CLI identity.

    """, stderr)
    exit(2)
}
let requestAccess = CommandLine.arguments.contains("--request-access")
var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
if requestAccess, status == .notDetermined {
    let semaphore = DispatchSemaphore(value: 0)
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
        status = newStatus
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 60)
    status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
}
func label(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .limited: return "limited"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}
guard status == .authorized else {
    fputs("""
    PhotoKit access unavailable to this CLI probe (status \(label(status)), raw \(status.rawValue)).
    No useful prompt is expected here. Run the in-app export from Photo Curator instead:
    Settings → Open Diagnostics… → Export Historical Metadata Audit…

    """, stderr)
    exit(3)
}
fputs("""
CLI PhotoKit access is authorized for this process identity, but the maintained path is the
in-app HistoricalMetadataAudit export. Prefer that so reports stay tied to Photo Curator's
permission and Info.plist.

""", stderr)
exit(4)
