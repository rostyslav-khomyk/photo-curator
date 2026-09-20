import SwiftUI

struct SyncReviewSheet: View {
    let review: SyncReview
    let isFrame: Bool
    let cancel: () -> Void
    let confirm: (Bool, Bool) -> Void
    @State private var replace = false
    @State private var skipUnresolved = false
    private var hasUnresolved: Bool { !(review.unresolvedFiles ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(isFrame ? "Update your desk photo frame" : "Review Google Photos sync",
                  systemImage: isFrame ? "photo.on.rectangle" : "rectangle.stack")
                .font(.title2.weight(.semibold))
            Text("\(review.fileCount) selected items · Up to \(ByteCountFormatter.string(fromByteCount: review.totalBytes, countStyle: .file)) to send")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(review.destinations) { destination in
                        HStack(alignment: .top) {
                            Image(systemName: destination.isNew ? "folder.badge.plus" : "rectangle.stack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title).font(.headline)
                                Text(destination.isNew
                                     ? "Will create this album with your selection."
                                     : "\(destination.existingCount) items now · \(destination.selectedCount) selected for this destination")
                                    .font(.callout).foregroundStyle(.secondary)
                                if destination.existingCount > destination.managedCount {
                                    Text("\(destination.existingCount - destination.managedCount) items are not accessible to Photo Relay and will be left untouched.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(height: min(180, CGFloat(review.destinations.count) * 78))

            if hasUnresolved {
                VStack(alignment: .leading, spacing: 8) {
                    Label("An earlier upload needs attention", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("Google did not confirm: \((review.unresolvedFiles ?? []).joined(separator: ", ")). These photos may already be in your Google library, even if no album exists.")
                        .font(.callout).foregroundStyle(.secondary)
                    Toggle("Leave unresolved photos out and add the rest", isOn: $skipUnresolved)
                    Text("No retry, no deletion. Confirmed uploads will be reused. Replacement is unavailable while photos are left out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if review.canReplace && !hasUnresolved {
                Picker("Update this selection", selection: $replace) {
                    Text("Add photos").tag(false)
                    Text("Replace Photo Relay photos").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(replace
                     ? "Add the new selection first, then remove the previous app-managed selection from these albums. The albums keep their identity. Photos stay in your Google library. Google may ask you to allow album editing."
                     : "Keep the current album contents and add this selection. Previously confirmed Photo Relay uploads are reused, not uploaded again.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !hasUnresolved {
                Text("No existing Photo Relay photos need replacing. Your selection will be added without removing anything.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if isFrame {
                Text("Your Nest Hub will pick up the updated album on its own schedule. Photo Relay cannot force the display to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(replace ? "Replace Album Selection" : "Add Selected Photos") { confirm(replace, skipUnresolved) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasUnresolved && !skipUnresolved)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}
