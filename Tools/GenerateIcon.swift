#!/usr/bin/env swift
import AppKit

// Generates AppIcon.iconset for CatHerder.
//
//   swift Tools/GenerateIcon.swift <output-directory>
//
// Design notes: pixel-art cats on leashes — herding cats being the job the app
// does. Everything is drawn on a coarse grid so the result reads as deliberate
// pixel art rather than a blurry illustration, and interpolation is disabled so
// the pixels stay crisp and square at 16pt as well as at 1024pt.

// MARK: - Palette

let backgroundTop = NSColor(srgbRed: 0.153, green: 0.176, blue: 0.227, alpha: 1)   // #272D3A
let backgroundBottom = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.090, alpha: 1) // #0E1017
let gingerCat = NSColor(srgbRed: 0.937, green: 0.616, blue: 0.353, alpha: 1)       // #EF9D5A
let creamCat = NSColor(srgbRed: 0.925, green: 0.878, blue: 0.804, alpha: 1)        // #ECE0CD
let leashColor = NSColor(srgbRed: 0.408, green: 0.780, blue: 0.671, alpha: 1)      // #68C7AB
let collarColor = NSColor(srgbRed: 0.882, green: 0.353, blue: 0.325, alpha: 1)     // #E15A53
let eyeColor = NSColor(srgbRed: 0.114, green: 0.129, blue: 0.169, alpha: 1)        // #1D212B

// MARK: - Sprites
//
// '#' coat, 'o' eye, 'c' collar, '.' transparent.

let catFacingRight = [
    "#.....#..",
    "##...##..",
    "#########",
    "#o###o###",
    "#########",
    ".ccccc###",
    ".######.#",
    ".######.#",
    ".#.##.#.#",
]

let catFacingLeft = [
    "..#.....#",
    "..##...##",
    "#########",
    "###o###o#",
    "#########",
    "###ccccc.",
    "#.######.",
    "#.######.",
    "#.#.##.#.",
]

/// The grip both leashes run up to.
let handSprite = [
    ".###.",
    "#####",
    "#####",
    ".###.",
]

// MARK: - Drawing

/// Cells across the icon. Coordinates below are in grid units, which is what
/// keeps the pixels aligned at every export size.
///
/// Small icons get a coarser grid and a single cat: at 32pt a 24-cell grid
/// leaves barely one pixel per cell, and two cats plus leashes turn to mush.
/// Simplifying the composition is what pixel art does instead of scaling down.
func gridSize(for size: CGFloat) -> CGFloat { size <= 64 ? 13 : 24 }

func drawIcon(size S: CGFloat) {
    let inset = S * 0.094
    let body = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let radius = body.width * 0.2237
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGradient(starting: backgroundTop, ending: backgroundBottom)?.draw(in: squircle, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    let grid = gridSize(for: S)
    let cell = body.width / grid
    let isCompact = grid < 20

    /// Fills one grid cell. Edges are rounded outward so neighbouring cells meet
    /// exactly, instead of leaving hairline seams at fractional pixel bounds.
    func fill(_ column: Int, _ row: Int, _ color: NSColor) {
        let x = body.minX + CGFloat(column) * cell
        // Grid rows count downward; AppKit's origin is bottom-left.
        let y = body.maxY - CGFloat(row + 1) * cell
        color.setFill()
        NSBezierPath(rect: NSRect(x: x.rounded(.down), y: y.rounded(.down),
                                  width: cell.rounded(.up), height: cell.rounded(.up))).fill()
    }

    func draw(_ sprite: [String], atColumn column: Int, row: Int, coat: NSColor) {
        for (dy, line) in sprite.enumerated() {
            for (dx, character) in line.enumerated() {
                let color: NSColor?
                switch character {
                case "#": color = coat
                case "o": color = eyeColor
                case "c": color = collarColor
                default:  color = nil
                }
                if let color { fill(column + dx, row + dy, color) }
            }
        }
    }

    /// Leashes are a staircase of cells, so they sit on the pixel grid rather
    /// than looking like a smooth stroke laid over pixel art.
    func drawLeash(from start: (column: Int, row: Int), to end: (column: Int, row: Int)) {
        var (x, y) = start
        while x != end.column || y != end.row {
            fill(x, y, leashColor)
            if y != end.row { y += y < end.row ? 1 : -1 }
            if x != end.column { x += x < end.column ? 1 : -1 }
        }
    }

    if isCompact {
        // One cat, filling the tile: still unmistakably a cat on a leash.
        draw(handSprite, atColumn: 7, row: 0, coat: creamCat)
        drawLeash(from: (8, 4), to: (4, 8))
        draw(catFacingRight, atColumn: 2, row: 4, coat: gingerCat)
    } else {
        draw(handSprite, atColumn: 10, row: 2, coat: creamCat)
        drawLeash(from: (11, 6), to: (6, 13))
        drawLeash(from: (13, 6), to: (17, 14))

        draw(catFacingRight, atColumn: 2, row: 13, coat: gingerCat)
        draw(catFacingLeft, atColumn: 13, row: 14, coat: creamCat)
    }

    NSGraphicsContext.restoreGraphicsState()

    // Top inner highlight, so the tile reads as an object rather than a shape.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let highlight = NSBezierPath(roundedRect: body.insetBy(dx: S * 0.006, dy: S * 0.006),
                                 xRadius: radius, yRadius: radius)
    highlight.lineWidth = max(1, S * 0.005)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    highlight.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    outline.lineWidth = max(1, S * 0.004)
    NSColor.black.withAlphaComponent(0.35).setStroke()
    outline.stroke()
}

// MARK: - Rendering

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .none
    drawIcon(size: CGFloat(size))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Iconset

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon.swift <output-directory>\n".utf8))
    exit(2)
}
let outputDirectory = CommandLine.arguments[1]
try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true)

/// (pixel size, iconset filenames) — iconutil expects both @1x and @2x names.
let variants: [(Int, [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for (size, names) in variants {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("failed to render \(size)\n".utf8))
        continue
    }
    for name in names {
        try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name)"))
    }
}
print("wrote iconset to \(outputDirectory)")
