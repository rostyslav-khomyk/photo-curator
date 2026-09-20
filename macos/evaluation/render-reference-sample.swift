// Contact sheets for explicitly approved exported copies. No Photos or network APIs.
import Foundation
import AppKit
import ImageIO
import CryptoKit

struct Sample: Decodable { let path: String; let sha256: String }
struct ReferenceCase: Decodable { let id: String; let samples: [Sample] }
struct Plan: Decodable { let root: String; let cases: [ReferenceCase] }

guard CommandLine.arguments.count == 2 else { fatalError("Provide evaluation report directory") }
let report = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: report.appendingPathComponent("reference-sample.json")))
let root = URL(fileURLWithPath: plan.root).resolvingSymlinksInPath()
guard report != root, !report.path.hasPrefix(root.path + "/"),
      plan.cases.flatMap(\.samples).count <= 160 else { fatalError("Invalid sample/output scope") }
let destination = report.appendingPathComponent("contact-sheets")
guard !FileManager.default.fileExists(atPath: destination.path) else { fatalError("Contact sheets already exist") }
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
for group in plan.cases {
    guard group.id.range(of: "^C[0-9]{2}$", options: .regularExpression) != nil else { fatalError("Invalid case ID") }
    for start in stride(from: 0, to: group.samples.count, by: 16) {
        try autoreleasepool {
            let samples = Array(group.samples[start..<min(start + 16, group.samples.count)])
            let rows = Int(ceil(Double(samples.count) / 4))
            let height = CGFloat(rows * 330 + 40)
            let canvas = NSImage(size: NSSize(width: 1600, height: height))
            canvas.lockFocus()
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1600, height: height).fill()
            let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.white]
            ("\(group.id) - sample page \(start / 16 + 1) (not a final Moment)" as NSString)
                .draw(at: NSPoint(x: 12, y: height - 28), withAttributes: style)
            for (offset, sample) in samples.enumerated() {
                let url = root.appendingPathComponent(sample.path).resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/") else { fatalError("Sample outside export") }
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == sample.sha256,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640
                      ] as CFDictionary) else { fatalError("Cannot load sample") }
                let x = CGFloat(offset % 4) * 400
                let y = CGFloat(rows - 1 - offset / 4) * 330
                let scale = min(388 / CGFloat(image.width), 296 / CGFloat(image.height))
                let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                NSImage(cgImage: image, size: size).draw(in: NSRect(x: x + (400 - size.width) / 2,
                    y: y + 28 + (296 - size.height) / 2, width: size.width, height: size.height))
                ("\(start + offset + 1): \(url.lastPathComponent)" as NSString)
                    .draw(at: NSPoint(x: x + 10, y: y + 6), withAttributes: style)
            }
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render") }
            let file = destination.appendingPathComponent("\(group.id)-\(start / 16 + 1).png")
            try png.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            print(file.path)
        }
    }
}
