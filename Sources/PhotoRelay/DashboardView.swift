import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: PhotoRelayViewModel
    @ObservedObject var curator: CuratorController

    var body: some View {
        VStack(spacing: 0) {
            LibraryAccessBanner(accessChanged: model.refreshPhotosAccess)
            CuratorView(curator: curator, model: model)
        }
        .navigationTitle("Photo Curator")
        .onAppear { CuratorLaunchPerformance.shared.finish() }
        .alert("Photo Curator", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task {
            await model.checkStartupAccess()
            await model.restoreUploadIfNeeded()
        }
        .onChange(of: model.isWorking) { busy in
            if !busy { model.refreshPhotosAccess() }
        }
        .alert("Photo Curator Access", isPresented: $model.showsAccessRecovery) {
            Button("Continue") { Task { await model.recoverAccess() } }
            Button("Not Now", role: .cancel) { }
        } message: { Text(model.accessRecoveryMessage) }
        .sheet(isPresented: $model.showsSyncReview) {
            if let review = model.syncReview {
                SyncReviewSheet(review: review, isFrame: true,
                    cancel: model.cancelSyncReview, confirm: model.confirmSync)
                    .interactiveDismissDisabled()
            }
        }
    }
}
