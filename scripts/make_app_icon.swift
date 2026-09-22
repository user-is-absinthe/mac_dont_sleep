#!/usr/bin/env swift
// Готовит AppIcon.icns из исходника pics/icon.png.
//
// Исходник — скруглённый квадрат с чёрными (непрозрачными) углами.
// Для icns углы должны быть прозрачными: альфа восстанавливается по
// яркости самого светлого канала (фон ~0, тёмно-синие детали чашки
// заметно ярче порога). Дальше — стандартный набор размеров icns.
//
// Использование: swift scripts/make_app_icon.swift

import Foundation
import CoreGraphics
import ImageIO

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // корень проекта

let inputURL = root.appendingPathComponent("pics/icon.png")
let outputURL = root.appendingPathComponent("Resources/AppIcon.icns")

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Не удалось прочитать pics/icon.png\n", stderr)
    exit(1)
}

let width = image.width
let height = image.height

guard let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Не удалось создать контекст\n", stderr)
    exit(2)
}
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
    fputs("Нет доступа к пикселям\n", stderr)
    exit(3)
}

// Прозрачность углов: альфа по максимальному каналу.
// Чёрный фон (~0) -> альфа 0; любые элементы рисунка (включая
// тёмно-синюю чашку) -> непрозрачные.
var minX = width, minY = height, maxX = -1, maxY = -1
for i in stride(from: 0, to: width * height * 4, by: 4) {
    let r = Int(pixels[i])
    let g = Int(pixels[i + 1])
    let b = Int(pixels[i + 2])
    let maxChannel = max(r, max(g, b))
    let alpha = max(0, min(255, (maxChannel - 6) * 255 / 20))
    // Валидный premultiplied: цвет умножаем на новую альфу
    pixels[i]     = UInt8(r * alpha / 255)
    pixels[i + 1] = UInt8(g * alpha / 255)
    pixels[i + 2] = UInt8(b * alpha / 255)
    pixels[i + 3] = UInt8(alpha)
    if alpha > 30 {
        let pixelIndex = i / 4
        let x = pixelIndex % width
        let y = pixelIndex / width
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}

print("Содержимое: x \(minX)...\(maxX), y \(minY)...\(maxY) из \(width)x\(height)")

guard let cleaned = ctx.makeImage() else {
    fputs("Не удалось собрать очищенное изображение\n", stderr)
    exit(4)
}

// icns: набор размеров от 16 до 1024
let sizes = [16, 32, 64, 128, 256, 512, 1024]
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    "com.apple.icns" as CFString,
    sizes.count,
    nil
) else {
    fputs("Не удалось создать \(outputURL.path)\n", stderr)
    exit(5)
}

for size in sizes {
    guard let scaled = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Не удалось создать контекст \(size)x\(size)\n", stderr)
        exit(6)
    }
    scaled.interpolationQuality = .high
    scaled.draw(cleaned, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaledImage = scaled.makeImage() else {
        fputs("Не удалось получить изображение \(size)x\(size)\n", stderr)
        exit(7)
    }
    CGImageDestinationAddImage(destination, scaledImage, nil)
}

guard CGImageDestinationFinalize(destination) else {
    fputs("Не удалось записать icns\n", stderr)
    exit(8)
}
print("✓ pics/icon.png -> \(outputURL.path)")