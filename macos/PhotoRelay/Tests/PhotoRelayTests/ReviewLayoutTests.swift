import XCTest
import SwiftUI
@testable import PhotoRelay

final class ReviewLayoutTests: XCTestCase {
    @MainActor
    func testFitAndCropKeepVisibleImageAtDifferentWidths() throws {
        let context = CGContext(data: nil, width: 120, height: 240, bitsPerComponent: 8,
                                bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
        let image = context.makeImage()!
        for width in [160.0, 340.0] {
            for crop in [false, true] {
                let renderer = ImageRenderer(content: PhotoPreviewCanvas(image: image, crop: crop)
                    .frame(width: width, height: 240).background(Color.black))
                let result = try XCTUnwrap(renderer.cgImage)
                let bitmap = NSBitmapImageRep(cgImage: result)
                let center = try XCTUnwrap(bitmap.colorAt(x: Int(width / 2), y: 120)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(center.redComponent, 0.9)
                let edge = try XCTUnwrap(bitmap.colorAt(x: 0, y: 120)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(edge.redComponent > 0.9, crop)
            }
        }
    }
}
