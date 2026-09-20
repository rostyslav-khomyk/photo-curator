// Read exported copies only. No PhotoKit access or network requests.
import Foundation
import Vision
import ImageIO
import CryptoKit
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    .filter { !$0.lastPathComponent.hasPrefix("contact-") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
var rows: [[String: Any]] = []
var seen = Set<String>()
var previews: [(String, CGImage)] = []
for url in urls {
    try autoreleasepool {
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard seen.insert(hash).inserted else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        let faces = VNDetectFaceRectanglesRequest()
        let labels = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, faces, labels])
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        rows.append([
            "file": url.lastPathComponent,
            "facesDetected": faces.results?.count ?? 0,
            "ocr": (text.results ?? []).compactMap { $0.topCandidates(1).first?.string },
            "labels": (labels.results ?? []).prefix(8).map { ["label": $0.identifier, "confidence": $0.confidence] as [String: Any] },
            "gps": properties[kCGImagePropertyGPSDictionary as String] ?? [:],
            "exif": properties[kCGImagePropertyExifDictionary as String] ?? [:]
        ])
        previews.append((url.lastPathComponent, image))
    }
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
try data.write(to: folder.appendingPathComponent("analysis.json"), options: .atomic)
print("Analyzed \(rows.count) exported copies; results saved beside copies.")
for start in stride(from: 0, to: previews.count, by: 10) {
    let page = NSImage(size: NSSize(width: 1500, height: 680))
    page.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1500, height: 680).fill()
    for (offset, preview) in previews[start..<min(start + 10, previews.count)].enumerated() {
        let x = CGFloat(offset % 5) * 300
        let y = CGFloat(1 - offset / 5) * 340
        let scale = min(280 / CGFloat(preview.1.width), 300 / CGFloat(preview.1.height))
        let size = NSSize(width: CGFloat(preview.1.width) * scale, height: CGFloat(preview.1.height) * scale)
        NSImage(cgImage: preview.1, size: size).draw(in: NSRect(x: x + (300-size.width)/2, y: y+30, width: size.width, height: size.height))
        (preview.0 as NSString).draw(at: NSPoint(x: x+10, y: y+8), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
    }
    page.unlockFocus()
    let bitmap = NSBitmapImageRep(data: page.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("contact-\(start / 10 + 1).png"))
}
