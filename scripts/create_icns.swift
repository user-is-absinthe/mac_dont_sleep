import AppKit
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: create_icns.swift input.png output.icns\\n", stderr)
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let sourceImage = NSImage(contentsOf: inputURL) else {
    fputs("Unable to read the source PNG.\\n", stderr)
    exit(65)
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    "com.apple.icns" as CFString,
    sizes.count,
    nil
) else {
    fputs("Unable to create the ICNS destination.\\n", stderr)
    exit(66)
}

for size in sizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Unable to create an image representation.\\n", stderr)
        exit(67)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let image = bitmap.cgImage else {
        fputs("Unable to render an icon representation.\\n", stderr)
        exit(68)
    }
    CGImageDestinationAddImage(destination, image, nil)
}

guard CGImageDestinationFinalize(destination) else {
    fputs("Unable to write the ICNS file.\\n", stderr)
    exit(69)
}
