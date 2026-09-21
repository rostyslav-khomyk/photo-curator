// Explicit exported-shortlist review only; no Photos or network access.
import Foundation
import AppKit
import ImageIO
import CryptoKit

struct Manifest: Decodable {
    struct Row: Decodable { let path: String; let sha256: String }
    let root: String; let rows: [Row]
}
struct Validation: Decodable {
    struct Moment: Decodable {
        struct Selection: Decodable { let selected: [String] }
        let selection: Selection
    }
    let scope: String; let catalog: [Moment]
}
guard CommandLine.arguments.count == 2 else { fatalError("Supply private report directory") }
let report = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: report.appendingPathComponent("manifest.json")))
let validation = try JSONDecoder().decode(Validation.self, from: Data(contentsOf: report.appendingPathComponent("large-validation.json")))
let root = URL(fileURLWithPath: manifest.root).resolvingSymlinksInPath()
let ids = validation.catalog.flatMap { $0.selection.selected }
guard validation.scope == "large", validation.catalog.count == 1, !ids.isEmpty, ids.count <= 64,
      Set(ids).count == ids.count, report != root, !report.path.hasPrefix(root.path + "/") else { fatalError("Invalid scope") }
let destination = report.appendingPathComponent("selected-review-" + UUID().uuidString)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
for start in stride(from: 0, to: ids.count, by: 12) {
    try autoreleasepool {
        let page = Array(ids[start..<min(start + 12, ids.count)])
        let rows = Int(ceil(Double(page.count) / 4)), height = CGFloat(rows * 330 + 40)
        let canvas = NSImage(size: NSSize(width: 1600, height: height))
        canvas.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1600, height: height).fill()
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.white]
        ("Actual large-visit shortlist: \(ids.count) selected, page \(start / 12 + 1)" as NSString).draw(at: NSPoint(x: 12, y: height - 28), withAttributes: style)
        for (index, id) in page.enumerated() {
            guard let row = manifest.rows.first(where: { $0.sha256 == id }) else { fatalError("Missing source") }
            let file = root.appendingPathComponent(row.path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { fatalError("Outside source") }
            let data = try Data(contentsOf: file)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == id,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { fatalError("Source changed") }
            let x = CGFloat(index % 4) * 400, y = CGFloat(rows - 1 - index / 4) * 330
            let scale = min(388 / CGFloat(image.width), 296 / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            NSImage(cgImage: image, size: size).draw(in: NSRect(x: x + (400 - size.width) / 2, y: y + 28 + (296 - size.height) / 2, width: size.width, height: size.height))
            ("\(start + index + 1): \(file.lastPathComponent)" as NSString).draw(at: NSPoint(x: x + 8, y: y + 6), withAttributes: style)
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
        let file = destination.appendingPathComponent("page-\(start / 12 + 1).png")
        try png.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        print(file.path)
    }
}
