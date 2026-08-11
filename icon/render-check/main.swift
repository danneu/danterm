// Renders every chip through ChipRenderer and writes a PNG per kind and
// appearance. Built by icon/render-check.sh with swiftc, against the real
// ChipArtwork.swift and ChipRenderer.swift -- no app build, no AppKit -- so the
// check exercises the code that ships rather than a stand-in for it.
//
// Usage: render-check <output-dir> <pixel-size>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3, let size = Int(arguments[2]), size > 0 else {
    FileHandle.standardError.write(Data("usage: render-check <output-dir> <pixel-size>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// Walk the generated list rather than naming kinds here: a chip added to
// chips.json is then covered by this check automatically.
let chips = ChipArtwork.all
let appearances: [(name: String, value: ChipAppearance)] = [("light", .light), ("dark", .dark)]

func newContext() -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write(Data("could not create a bitmap context\n".utf8))
        exit(1)
    }
    return context
}

/// The pixels of a context, so two renderings can be compared exactly.
func pixels(of context: CGContext) -> Data {
    Data(bytes: context.data!, count: context.bytesPerRow * context.height)
}

for (name, definition) in chips {
    for (appearanceName, appearance) in appearances {
        let context = newContext()
        let rect = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        ChipRenderer.draw(definition, in: context, rect: rect, appearance: appearance, flipped: false)

        // The `flipped: true` path is the one every NSView will take, so prove
        // it lands identically: a y-down context plus a flipped draw must
        // produce the same pixels as a y-up context plus an unflipped one.
        let mirrored = newContext()
        mirrored.translateBy(x: 0, y: CGFloat(size))
        mirrored.scaleBy(x: 1, y: -1)
        ChipRenderer.draw(definition, in: mirrored, rect: rect, appearance: appearance, flipped: true)
        guard pixels(of: context) == pixels(of: mirrored) else {
            FileHandle.standardError.write(
                Data("flipped and unflipped renderings differ for \(name)-\(appearanceName)\n".utf8)
            )
            exit(1)
        }

        let url = outputDirectory.appendingPathComponent("\(name)-\(appearanceName).png")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else {
            FileHandle.standardError.write(Data("could not encode \(url.lastPathComponent)\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            FileHandle.standardError.write(Data("could not write \(url.lastPathComponent)\n".utf8))
            exit(1)
        }
        print("wrote \(url.lastPathComponent)")
    }
}
