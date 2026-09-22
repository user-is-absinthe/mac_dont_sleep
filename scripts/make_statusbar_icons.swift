#!/usr/bin/env swift
// Готовит иконки для статус-бара из исходников в pics/.
//
// Исходники — белые пиктограммы на чёрном фоне. Для macOS нужны PNG
// с прозрачным фоном (template image: цвет меню-бара подставит система).
// Скрипт: превращает яркость пикселя в альфу, обрезает по содержимому,
// делает квадратный холст и уменьшает до нужного размера.
//
// Использование: swift scripts/make_statusbar_icons.swift

import Foundation
import CoreGraphics
import ImageIO

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // корень проекта

struct Job {
    let source: String
    let destination: String
}

let jobs: [Job] = [
    Job(source: "pics/statusbar.png", destination: "Resources/StatusBarIdle.png"),
    Job(source: "pics/statusbar-awake.png", destination: "Resources/StatusBarAwake.png"),
]

func makeIcon(_ job: Job, outputSize: Int = 72) throws {
    let srcURL = root.appendingPathComponent(job.source)
    let dstURL = root.appendingPathComponent(job.destination)

    guard let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    throw NSError(domain: "StatusBarIcons", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать \(job.source)"])
    }

    let width = image.width
    let height = image.height

    // Рисуем в RGBA-контекст
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
    throw NSError(domain: "StatusBarIcons", code: 2)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let base = ctx.data else {
    throw NSError(domain: "StatusBarIcons", code: 3)
    }
    let pixels = base.assumingMemoryBound(to: UInt8.self)

    // Альфа = яркость (белый силуэт на чёрном фоне), цвет — белый
    // (template-иконка использует только альфу).
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let r = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let b = Int(pixels[offset + 2])
            let luminance = (299 * r + 587 * g + 114 * b) / 1000
            let alpha = max(0, min(255, (luminance - 10) * 255 / 200))
            // Валидные premultiplied значения: белый глиф → RGB = альфа.
            // (RGB > alpha ломает отрисовку: CoreGraphics поднимает альфу.)
            pixels[offset] = UInt8(alpha)
            pixels[offset + 1] = UInt8(alpha)
            pixels[offset + 2] = UInt8(alpha)
            pixels[offset + 3] = UInt8(alpha)
            if luminance > 30 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else {
    throw NSError(domain: "StatusBarIcons", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "Пустое изображение \(job.source)"])
    }

    // Обрезка по содержимому с полями, приведение к квадрату
    let boxWidth = maxX - minX + 1
    let boxHeight = maxY - minY + 1
    let side = max(boxWidth, boxHeight)
    let pad = side / 16
    let paddedSide = side + pad * 2
    var cx = (minX + maxX + 1) / 2
    var cy = (minY + maxY + 1) / 2
    var left = cx - paddedSide / 2
    var bottom = cy - paddedSide / 2
    left = max(0, min(left, width - paddedSide))
    bottom = max(0, min(bottom, height - paddedSide))
    let cropRect = CGRect(x: left, y: bottom, width: paddedSide, height: paddedSide)

    let modified: CGImage
    guard let m = ctx.makeImage() else {
    throw NSError(domain: "StatusBarIcons", code: 5)
    }
    modified = m
    guard let cropped = modified.cropping(to: cropRect) else {
    throw NSError(domain: "StatusBarIcons", code: 5)
    }

    // Масштаб до outputSize
    guard let outCtx = CGContext(
        data: nil,
        width: outputSize,
        height: outputSize,
        bitsPerComponent: 8,
        bytesPerRow: outputSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
    throw NSError(domain: "StatusBarIcons", code: 6)
    }
    outCtx.interpolationQuality = .high
    outCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

    guard let output = outCtx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(dstURL as CFURL, "public.png" as CFString, 1, nil) else {
    throw NSError(domain: "StatusBarIcons", code: 7)
    }
    CGImageDestinationAddImage(dest, output, nil)
    guard CGImageDestinationFinalize(dest) else {
    throw NSError(domain: "StatusBarIcons", code: 8)
    }
    print("✓ \(job.source) -> \(job.destination) (\(outputSize)x\(outputSize))")
}

do {
    for job in jobs {
        try makeIcon(job)
    }
} catch {
    print("Ошибка: \(error)")
    exit(1)
}