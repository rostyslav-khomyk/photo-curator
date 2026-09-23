import AppKit
import Foundation
import Photos

enum GoogleDestinationMode: String, CaseIterable, Identifiable {
    case matching
    case custom
    case frame

    var id: Self { self }
    var title: String {
        switch self {
        case .matching: "Match Photos album names"
        case .custom: "Choose custom albums…"
        case .frame: "Desk photo frame"
        }
    }
}

@MainActor
final class PhotoRelayViewModel: ObservableObject {
    @Published var albums: [PhotosAlbum] = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var exportDirectory: String
    @Published var skipVideos: Bool { didSet { UserDefaults.standard.set(skipVideos, forKey: "google.skipVideos") } }
    @Published var skipLivePhotos: Bool { didSet { UserDefaults.standard.set(skipLivePhotos, forKey: "google.skipLivePhotos") } }
    @Published var googleEnabled = false
    @Published private(set) var googleConnected: Bool
    @Published var destinationMode = GoogleDestinationMode.matching
    @Published var customAlbumMappings: [String: String] = [:]
    @Published var showsGoogleAlbumPicker = false
    @Published var googleAlbums: [GoogleAlbum] = []
    @Published var frameAlbumID: String {
        didSet { UserDefaults.standard.set(frameAlbumID, forKey: "frameAlbumID") }
    }
    @Published var frameAlbumTitle: String {
        didSet { UserDefaults.standard.set(frameAlbumTitle, forKey: "frameAlbumTitle") }
    }
    @Published var syncReview: SyncReview?
    @Published var showsSyncReview = false
    @Published private(set) var transferProgress: TransferProgress?
    @Published var isLoadingAlbums = false
    @Published private(set) var albumLoadAttempted = false
    @Published private(set) var albumLoadError: String?
    @Published private(set) var googleUploadedAssetIDs: Set<String>
    private var hadPhotosAccess = false
    private var preparedGoogleItems: [ExportedPhotosItem] = []
    private var pendingGoogleAssetIDs: Set<String> = []

    func refreshPhotosAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let readable = status == .authorized || status == .limited
        guard !isWorking else { return }
        if !readable {
            hadPhotosAccess = false
            albumLoadAttempted = false
            albums = []
            return
        }
        if !hadPhotosAccess {
            hadPhotosAccess = true
            albumLoadAttempted = false
        }
        if !albumLoadAttempted && !isLoadingAlbums { loadAlbums() }
    }
    @Published var isWorking = false
    @Published private(set) var isAborting = false
    @Published private var activeUploadID: String?
    var canAbortUpload: Bool { isWorking && activeUploadID != nil }
    @Published var activity = "Choose albums to begin."
    @Published var errorMessage: String?
    @Published var showsAccessRecovery = false
    @Published var accessRecoveryMessage = ""
    private var googleNeedsRecovery = false
    private var startupAccessChecked = false

    func checkStartupAccess() async {
        guard !startupAccessChecked, !isWorking else { return }
        startupAccessChecked = true
        await checkGoogleAccess()
        let photosMissing = PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized
        var missing: [String] = []
        if photosMissing { missing.append("Allow full Photos library access for Moments.") }
        if googleNeedsRecovery {
            missing.append("Reconnect Google for Photos sync and album updates.")
        }
        accessRecoveryMessage = missing.joined(separator: "\n\n")
        showsAccessRecovery = !missing.isEmpty
    }

    func recoverAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else if status == .denied || status == .limited {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                NSWorkspace.shared.open(url)
            }
        }
        NotificationCenter.default.post(name: .photoRelayPhotosAccessChanged, object: nil)
        refreshPhotosAccess()
        if googleNeedsRecovery { await checkGoogleAccess(interactive: true) }
    }

    func checkGoogleAccess(interactive: Bool = false) async {
        guard !isWorking, let googleOAuth else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if interactive { try await googleOAuth.authorize(scopes: Self.googleScopes) }
            _ = try await googleOAuth.accessToken(scopes: Self.googleScopes, forceRefresh: false)
            googleNeedsRecovery = false
            googleConnected = true
        } catch GoogleOAuthError.authorizationRequired {
            googleNeedsRecovery = true
            googleConnected = false
        } catch {
            // A transient check failure must not clear the saved login or force consent.
        }
    }

    private let photosSource = PhotosLibrarySource()
    private let googleCredentials: String
    private let googleOAuth: NativeGoogleOAuth?
    private let googleClient: NativeGooglePhotosClient?
    private let googleSync: NativeGoogleSync?
    private let albumMapping: String
    private static let googleScopes: Set<String> = [
        NativeGoogleOAuth.identityScope,
        NativeGooglePhotosClient.appendScope,
        NativeGooglePhotosClient.readScope,
        NativeGooglePhotosClient.editScope,
    ]

    init() {
        let defaults = UserDefaults.standard
        frameAlbumID = defaults.string(forKey: "frameAlbumID") ?? ""
        frameAlbumTitle = defaults.string(forKey: "frameAlbumTitle") ?? "Desk Travels"
        skipVideos = defaults.object(forKey: "google.skipVideos") as? Bool ?? true
        skipLivePhotos = defaults.object(forKey: "google.skipLivePhotos") as? Bool ?? true
        if defaults.bool(forKey: "usesDeskFrame") { destinationMode = .frame }
        exportDirectory = defaults.string(forKey: "exportDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Photo Relay").path
        googleCredentials = Self.prepareGoogleCredentials(defaults: defaults)
        if googleCredentials.isEmpty {
            googleOAuth = nil
            googleClient = nil
            googleSync = nil
        } else {
            let oauth = NativeGoogleOAuth(credentialsURL: URL(fileURLWithPath: googleCredentials))
            let client = NativeGooglePhotosClient(tokens: oauth)
            let ledger = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photo Relay/photo_curator_uploads.sqlite3")
            googleOAuth = oauth
            googleClient = client
            googleSync = try? NativeGoogleSync(client: client, ledgerURL: ledger)
        }
        albumMapping = defaults.string(forKey: "albumMapping")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photo Relay/album_mapping.json").path
        googleConnected = Self.hasGoogleToken(for: googleCredentials)
        googleUploadedAssetIDs = Set(defaults.stringArray(forKey: "google.uploadedAssetIDs.v1") ?? [])
        pendingGoogleAssetIDs = Set(defaults.stringArray(forKey: "google.pendingAssetIDs.v1") ?? [])
    }

    var selectedCount: Int { selectedAlbumIDs.count }
    var canStart: Bool {
        !isWorking && !selectedAlbumIDs.isEmpty && !exportDirectory.isEmpty
            && (!googleEnabled || (googleConnected && hasCompleteDestinationMapping))
    }

    var selectedAlbumNames: [String] {
        Array(Set(albums.filter { selectedAlbumIDs.contains($0.id) }.map(\.title))).sorted()
    }

    var hasCompleteDestinationMapping: Bool {
        if destinationMode == .frame {
            return !frameAlbumID.isEmpty || !frameAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return destinationMode == .matching
            || selectedAlbumNames.allSatisfy { customAlbumMappings[$0]?.isEmpty == false }
    }

    func loadAlbums() {
        guard !isLoadingAlbums, !isWorking else { return }
        albumLoadAttempted = true
        albumLoadError = nil
        isLoadingAlbums = true
        activity = "Reading your Photos library…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let albums = try await photosSource.listAlbums()
                self.isLoadingAlbums = false
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard status == .authorized || status == .limited else {
                    self.refreshPhotosAccess()
                    return
                }
                self.albums = albums
                self.hadPhotosAccess = true
                self.selectedAlbumIDs.formIntersection(Set(albums.map(\.id)))
                if !self.isWorking { self.activity = "Choose the albums you want to export." }
            } catch {
                self.isLoadingAlbums = false
                self.albumLoadError = error.localizedDescription
                if !self.isWorking { self.activity = "Could not load Photos albums. Retry in the sidebar." }
            }
        }
    }

    func toggleAlbum(_ album: PhotosAlbum) {
        guard !isWorking else { return }
        if selectedAlbumIDs.contains(album.id) {
            selectedAlbumIDs.remove(album.id)
        } else {
            selectedAlbumIDs.insert(album.id)
        }
    }

    func clearSelection() {
        guard !isWorking else { return }
        selectedAlbumIDs.removeAll()
    }

    func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: exportDirectory, isDirectory: true)
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        exportDirectory = path
        UserDefaults.standard.set(path, forKey: "exportDirectory")
    }

    func signInToGoogle(showAlbumPicker: Bool = false) {
        guard !isWorking else { return }
        guard let googleOAuth, let googleClient else {
            errorMessage = "Google sign-in is not configured in this build of Photo Relay."
            return
        }
        isWorking = true
        activity = "Connecting to Google Photos in your browser…"
        Task {
            do {
                if try await googleOAuth.isConnected(scopes: Self.googleScopes) == false {
                    try await googleOAuth.authorize(scopes: Self.googleScopes)
                }
                googleAlbums = try await googleClient.listAlbums()
                googleConnected = true
                if showAlbumPicker {
                    showsGoogleAlbumPicker = true
                }
                activity = googleAlbums.isEmpty
                    ? "Google Photos is connected. No app-created albums exist yet."
                    : "Google Photos is connected."
            } catch {
                googleConnected = false
                errorMessage = error.localizedDescription
                activity = "Google Photos connection failed."
            }
            isWorking = false
        }
    }

    func chooseCustomGoogleAlbums() {
        guard googleConnected else { return }
        if googleAlbums.isEmpty {
            signInToGoogle(showAlbumPicker: true)
        } else {
            showsGoogleAlbumPicker = true
        }
    }

    func startSync() {
        guard canStart else { return }
        let selections = albums
            .filter { selectedAlbumIDs.contains($0.id) }
            .map { PhotosAlbumSelection(id: $0.id, title: $0.title) }
        guard !selections.isEmpty else { return }
        isWorking = true
        transferProgress = nil
        UserDefaults.standard.set(destinationMode == .frame, forKey: "usesDeskFrame")
        activity = "Preparing your Photos library…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await photosSource.export(
                    selections: selections,
                    directory: exportDirectory,
                    skipVideos: skipVideos,
                    skipLivePhotos: skipLivePhotos,
                    recent: nil,
                    dryRun: false,
                    progress: { [weak self] message in self?.activity = message }
                )
                self.activity = "Exported \(items.count) item(s). Preparing destination…"
                await self.startUpload(items: items)
            } catch {
                self.isWorking = false
                self.errorMessage = error.localizedDescription
                self.activity = "Export failed."
            }
        }
    }

    func startMomentSync(moments: [PhotoMoment], decisions: MomentReviewDecisions, favoritesOnly: Bool) {
        guard !isWorking, googleConnected else { return }
        var ids: [String] = []
        if moments.isEmpty, favoritesOnly {
            let options = PHFetchOptions()
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
                NSPredicate(format: "favorite == YES")
            ])
            options.includeHiddenAssets = false
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
        }
        for moment in moments {
            let selected: [String]
            if favoritesOnly {
                let candidateIDs = moment.photos.map(\.id)
                let current = PHAsset.fetchAssets(withLocalIdentifiers: candidateIDs, options: nil)
                var favorites: [String] = []
                current.enumerateObjects { asset, _, _ in
                    if asset.isFavorite { favorites.append(asset.localIdentifier) }
                }
                selected = favorites
            } else if let selection = moment.selection {
                selected = MomentReviewDecisions.apply(decisions.values, to: selection, photos: moment.photos).selected
            } else {
                selected = moment.photos.map(\.id)
            }
            ids.append(contentsOf: selected)
        }
        ids = Array(Set(ids))
        guard !ids.isEmpty else {
            errorMessage = favoritesOnly
                ? (moments.isEmpty ? "Your Photos library contains no Favorites." : "The selected Moments contain no Photos Favorites.")
                : "The selected Moments contain no highlights."
            return
        }
        googleEnabled = true
        clearPendingGoogleAssets()
        destinationMode = .frame
        isWorking = true
        transferProgress = nil
        activity = "Preparing selected Moments for Google Photos…"
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Curator/Google Staging", isDirectory: true).path
        Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await photosSource.export(
                    assetIDs: ids,
                    albumTitle: "Selected Moments",
                    directory: cache,
                    skipVideos: skipVideos,
                    skipLivePhotos: skipLivePhotos,
                    progress: { [weak self] message in self?.activity = message }
                )
                await self.startUpload(items: items)
            } catch {
                self.isWorking = false
                self.errorMessage = error.localizedDescription
                self.activity = "Could not prepare selected Moments."
            }
        }
    }

    func clearGoogleAlbum(id: String) {
        guard googleConnected, !isWorking, !id.isEmpty, let googleSync else { return }
        isWorking = true
        activity = "Clearing the Google Photos album…"
        Task {
            do {
                let removed = try await googleSync.clearAlbum(id)
                googleAlbums = googleAlbums.map { album in
                    album.id == id
                        ? GoogleAlbum(id: album.id, title: album.title,
                                      mediaItemsCount: String(max(0, album.count - removed)))
                        : album
                }
                activity = "Cleared \(removed) photo(s) from the Google album. The photos remain in your library."
            } catch {
                errorMessage = error.localizedDescription
                activity = "Could not clear the Google Photos album."
            }
            isWorking = false
        }
    }

    private func startUpload(items: [ExportedPhotosItem]) async {
        do {
            if !googleEnabled {
                isWorking = false
                activity = "Export complete: \(items.count) item(s)."
                return
            }
            guard let googleSync else { throw RelayError.message("Google Photos is not configured.") }
            preparedGoogleItems = items
            var destinations: [String: NativeGoogleSync.DestinationChoice] = [:]
            for source in Set(items.map(\.album)) {
                switch destinationMode {
                case .matching: destinations[source] = .init(id: nil, title: source)
                case .custom:
                    guard let id = customAlbumMappings[source] else {
                        throw RelayError.message("Choose a Google destination for \(source).")
                    }
                    destinations[source] = .init(id: id, title: nil)
                case .frame:
                    destinations[source] = frameAlbumID.isEmpty
                        ? .init(id: nil, title: frameAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                        : .init(id: frameAlbumID, title: nil)
                }
            }
            activity = "Checking your Google destination before making changes…"
            syncReview = try await googleSync.prepare(items: items, choices: destinations)
            showsSyncReview = true
            activity = "Review how to update your Google album."
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
            activity = "Sync failed."
        }
    }

    func cancelSyncReview() {
        showsSyncReview = false
        syncReview = nil
        preparedGoogleItems = []
        clearPendingGoogleAssets()
        isWorking = false
        StorageMaintenance.removeGoogleStaging()
        activity = "Sync canceled. Temporary files were removed; Google Photos was not changed."
    }

    func confirmSync(replace: Bool, skipUnresolved: Bool) {
        guard let review = syncReview, let googleSync else { return }
        let unresolved = Set(review.unresolvedFiles ?? [])
        pendingGoogleAssetIDs = Set(preparedGoogleItems.compactMap { item in
            guard !skipUnresolved || !unresolved.contains(item.path) else { return nil }
            return item.assetID
        })
        UserDefaults.standard.set(Array(pendingGoogleAssetIDs), forKey: "google.pendingAssetIDs.v1")
        showsSyncReview = false
        syncReview = nil
        activity = "Starting Google Photos sync…"
        Task {
            do {
                try await googleSync.start(token: review.token, replace: replace, skipUnresolved: skipUnresolved)
                activeUploadID = review.token
                await monitorUpload(expectedRunID: review.token)
            } catch {
                isWorking = false
                clearPendingGoogleAssets()
                errorMessage = error.localizedDescription
                activity = "Sync did not start. Review the selection again."
            }
        }
    }

    func restoreUploadIfNeeded() async {
        guard !isWorking, let state = await googleSync?.snapshot(), state.running else { return }
        isWorking = true
        await monitorUpload()
    }

    func abortUpload() {
        guard canAbortUpload, !isAborting, googleSync != nil else { return }
        isAborting = true
        activity = "Aborting; waiting for any in-flight Google request to finish…"
        Task { await googleSync?.abort() }
    }

    private func monitorUpload(expectedRunID: String? = nil) async {
        defer {
            activeUploadID = nil
            isAborting = false
        }
        while true {
            try? await Task.sleep(for: .seconds(1))
            guard let state = await googleSync?.snapshot() else {
                isWorking = false
                clearPendingGoogleAssets()
                errorMessage = "Google Photos is not configured."
                return
            }
                if let expectedRunID, state.progress?.runID != expectedRunID {
                    if state.running {
                        activity = "Waiting for the local service to identify this sync…"
                        continue
                    }
                    isWorking = false
                    clearPendingGoogleAssets()
                    activity = "This sync was not confirmed. Review the selection and try again."
                    return
                }
                transferProgress = state.progress
                activeUploadID = state.progress?.runID
                if state.progress?.phase == "aborting" { isAborting = true }
                if let progress = state.progress { activity = progress.message }
                if state.running { continue }
                isWorking = false
                StorageMaintenance.removeGoogleStaging()
                if state.progress?.phase == "aborted" {
                    clearPendingGoogleAssets()
                    activity = "Upload aborted. Completed changes were kept; remaining work was stopped."
                } else if let error = state.error {
                    clearPendingGoogleAssets()
                    errorMessage = error
                    activity = "Google Photos upload failed."
                } else if state.succeeded {
                    googleUploadedAssetIDs.formUnion(pendingGoogleAssetIDs)
                    UserDefaults.standard.set(Array(googleUploadedAssetIDs), forKey: "google.uploadedAssetIDs.v1")
                    clearPendingGoogleAssets()
                    activity = state.progress?.message ?? "Google album updated."
                    if destinationMode == .frame, let destination = state.progress?.destinations?.first {
                        frameAlbumID = destination.id
                        frameAlbumTitle = destination.title
                    }
                } else {
                    clearPendingGoogleAssets()
                    activity = "No active sync. Review your selection and try again."
                }
                return
        }
    }

    func momentWasUploaded(_ assetIDs: [String]) -> Bool {
        !assetIDs.isEmpty && Set(assetIDs).isSubset(of: googleUploadedAssetIDs)
    }

    var uploadedGoogleAssetIDs: Set<String> { googleUploadedAssetIDs }

    private func clearPendingGoogleAssets() {
        pendingGoogleAssetIDs = []
        preparedGoogleItems = []
        UserDefaults.standard.removeObject(forKey: "google.pendingAssetIDs.v1")
    }

    private static func prepareGoogleCredentials(defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: "googleCredentials"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Photo Relay", isDirectory: true)
        let destination = supportDirectory.appendingPathComponent("google_credentials.json")
        if !FileManager.default.fileExists(atPath: destination.path),
           let bundled = Bundle.main.resourceURL?
               .appendingPathComponent("Google", isDirectory: true)
               .appendingPathComponent("google_credentials.json"),
           FileManager.default.fileExists(atPath: bundled.path) {
            try? FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: bundled, to: destination)
        }
        return FileManager.default.fileExists(atPath: destination.path) ? destination.path : ""
    }

    private static func hasGoogleToken(for credentials: String) -> Bool {
        guard !credentials.isEmpty else { return false }
        let url = URL(fileURLWithPath: credentials)
        let token = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)_token.\(url.pathExtension)"
        )
        if let data = try? Data(contentsOf: token),
           let contents = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refreshToken = contents["refresh_token"] as? String, !refreshToken.isEmpty {
            return true
        }
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let client = (contents["installed"] ?? contents["web"]) as? [String: Any],
              let clientID = client["client_id"] as? String else { return false }
        return (try? KeychainGoogleTokenStore().load(clientID: clientID)) != nil
    }
}

private enum RelayError: LocalizedError {
    case noResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noResponse: "The local Photo Relay service did not respond."
        case .message(let message): message
        }
    }
}
