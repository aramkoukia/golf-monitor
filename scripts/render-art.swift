#!/usr/bin/env swift
// Renders GolfMonitor's app icons (iPhone + Apple Watch) and the launch
// artwork with Core Graphics, so the art lives in code and can be tweaked.
//
//   swift scripts/render-art.swift            # writes into the asset catalogs
//   swift scripts/render-art.swift /tmp/art   # writes previews somewhere else
//
// The splash geometry (ball, tracer) is mirrored in
// GolfMonitor/App/SplashView.swift — change both together.

import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (matches Theme.Palette)

struct RGB { var r, g, b: CGFloat; var a: CGFloat = 1 }
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> RGB {
    RGB(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255, a: a)
}
extension RGB {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func alpha(_ a: CGFloat) -> RGB { RGB(r: r, g: g, b: b, a: a) }
}

let void = rgb(0x050607)
let nightTop = rgb(0x020306)
let nightMid = rgb(0x06121A)
let horizonSky = rgb(0x153028)
let turfNear = rgb(0x03100A)
let turfFar = rgb(0x0F3A29)
let plasma = rgb(0xFF5A1F)
let ember = rgb(0xFF8A3D)
let tracer = rgb(0xFFE7B0)
let ion = rgb(0x3DF5A6)
let floodlight = rgb(0xF2F5F2)

// MARK: - Canvas helpers

final class Canvas {
    let width: Int, height: Int
    let ctx: CGContext
    var w: CGFloat { CGFloat(width) }
    var h: CGFloat { CGFloat(height) }

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left origin, y down, like UIKit.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
    }

    func image() -> CGImage { ctx.makeImage()! }

    /// Draws `draw` on a transparent layer, blurs it and adds it on top (glow).
    func glow(radius: CGFloat, intensity: CGFloat = 1, _ draw: (CGContext) -> Void) {
        let layer = Canvas(width, height)
        draw(layer.ctx)
        let input = CIImage(cgImage: layer.image())
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let out = ci.createCGImage(blurred, from: input.extent) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.setAlpha(intensity)
        drawImage(out)
        ctx.restoreGState()
    }

    /// Draws a CGImage filling the canvas (undoing the y flip for images).
    func drawImage(_ image: CGImage) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }
}

func linear(_ ctx: CGContext, _ stops: [(CGFloat, RGB)], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map(\.1.cg) as CFArray, locations: stops.map(\.0))!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ stops: [(CGFloat, RGB)], center: CGPoint, radius: CGFloat,
            scaleY: CGFloat = 1, from: CGPoint? = nil, startRadius: CGFloat = 0) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map(\.1.cg) as CFArray, locations: stops.map(\.0))!
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: scaleY)
    let start = from.map { CGPoint(x: $0.x - center.x, y: ($0.y - center.y) / scaleY) } ?? .zero
    ctx.drawRadialGradient(gradient, startCenter: start, startRadius: startRadius,
                           endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
}

// MARK: - Scene pieces

struct Cubic {
    var p0, c1, c2, p3: CGPoint
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }
}

/// Night sky over the range: deep blue-black, a warm haze on the horizon
/// and floodlights on poles.
func sky(_ c: Canvas, horizon: CGFloat, lights: [CGPoint], scale s: CGFloat) {
    let ctx = c.ctx
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: c.w, height: horizon + 2))
    linear(ctx, [(0, nightTop), (0.55, nightMid), (1, horizonSky)],
           from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: horizon))
    // Warm haze where the floodlit range meets the sky.
    radial(ctx, [(0, plasma.alpha(0.42)), (0.35, plasma.alpha(0.16)), (1, plasma.alpha(0))],
           center: CGPoint(x: c.w * 0.62, y: horizon), radius: c.w * 0.75, scaleY: 0.22)
    ctx.restoreGState()
    for light in lights {
        c.glow(radius: 26 * s, intensity: 0.9) { g in
            radial(g, [(0, tracer.alpha(0.9)), (1, tracer.alpha(0))], center: light, radius: 60 * s)
        }
        radial(ctx, [(0, floodlight), (0.4, tracer.alpha(0.85)), (1, tracer.alpha(0))], center: light, radius: 9 * s)
        // Pole.
        ctx.setStrokeColor(rgb(0x0A1512).cg)
        ctx.setLineWidth(3 * s)
        ctx.move(to: CGPoint(x: light.x, y: light.y + 8 * s))
        ctx.addLine(to: CGPoint(x: light.x, y: horizon))
        ctx.strokePath()
    }
}

/// Turf in perspective: mowing stripes fanning from the vanishing point and
/// faint distance rings.
func turf(_ c: Canvas, horizon: CGFloat, vanishX: CGFloat, scale s: CGFloat) {
    let ctx = c.ctx
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: horizon, width: c.w, height: c.h - horizon))
    linear(ctx, [(0, turfFar), (0.35, rgb(0x0A2A1D)), (1, turfNear)],
           from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: c.h))
    let vanish = CGPoint(x: vanishX, y: horizon - (c.h - horizon) * 0.08)
    let stripes = 14
    for i in 0..<stripes where i % 2 == 0 {
        let x0 = -c.w * 1.2 + CGFloat(i) / CGFloat(stripes) * c.w * 3.4
        let x1 = -c.w * 1.2 + CGFloat(i + 1) / CGFloat(stripes) * c.w * 3.4
        ctx.move(to: vanish)
        ctx.addLine(to: CGPoint(x: x0, y: c.h))
        ctx.addLine(to: CGPoint(x: x1, y: c.h))
        ctx.closePath()
        ctx.setFillColor(rgb(0x2BD18A, 0.035).cg)
        ctx.fillPath()
    }
    // Distance rings (target greens), flattened by perspective.
    for (i, depth) in [0.12, 0.32, 0.62].enumerated() {
        let y = horizon + (c.h - horizon) * CGFloat(depth)
        let rx = c.w * (0.16 + 0.36 * CGFloat(depth))
        let ry = rx * (0.08 + 0.22 * CGFloat(depth))
        ctx.setStrokeColor((i == 0 ? tracer : ion).alpha(0.10 + 0.04 * CGFloat(i)).cg)
        ctx.setLineWidth((1.2 + CGFloat(i)) * s)
        ctx.strokeEllipse(in: CGRect(x: vanishX + c.w * 0.18 * (1 - CGFloat(depth)) - rx, y: y - ry,
                                     width: rx * 2, height: ry * 2))
    }
    // Light falling on the turf near the horizon.
    radial(ctx, [(0, tracer.alpha(0.10)), (1, tracer.alpha(0))],
           center: CGPoint(x: c.w * 0.6, y: horizon), radius: c.w * 0.6, scaleY: 0.25)
    ctx.restoreGState()
    // Crisp horizon line.
    ctx.setStrokeColor(tracer.alpha(0.18).cg)
    ctx.setLineWidth(1.5 * s)
    ctx.move(to: CGPoint(x: 0, y: horizon))
    ctx.addLine(to: CGPoint(x: c.w, y: horizon))
    ctx.strokePath()
}

/// A dimpled golf ball, lit from the upper left with a warm rim light from
/// the floodlit horizon.
func ball(_ c: Canvas, center: CGPoint, radius r: CGFloat) {
    let ctx = c.ctx
    // Contact shadow on the turf.
    radial(ctx, [(0, rgb(0x000000, 0.65)), (1, rgb(0x000000, 0))],
           center: CGPoint(x: center.x + r * 0.15, y: center.y + r * 0.95), radius: r * 1.25, scaleY: 0.22)
    // Halo so the ball pops off the dark scene.
    c.glow(radius: r * 0.5, intensity: 0.55) { g in
        g.setFillColor(floodlight.alpha(0.55).cg)
        g.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    ctx.clip()
    let light = CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.42)
    radial(ctx, [(0, rgb(0xFFFFFF)), (0.45, rgb(0xEEF1F2)), (0.8, rgb(0xC3CAD0)), (1, rgb(0x8A939B))],
           center: center, radius: r, from: light)

    // Dimples: points on a sphere, projected; foreshortened toward the edge.
    let n = 420
    let golden = CGFloat.pi * (3 - sqrt(5))
    let tilt: CGFloat = 0.55, spin: CGFloat = 0.3
    for i in 0..<n {
        let y = 1 - (CGFloat(i) + 0.5) / CGFloat(n) * 2
        let rad = sqrt(1 - y * y)
        let theta = golden * CGFloat(i) + spin
        var p = (x: cos(theta) * rad, y: y, z: sin(theta) * rad)
        // Tilt around x.
        p = (x: p.x, y: p.y * cos(tilt) - p.z * sin(tilt), z: p.y * sin(tilt) + p.z * cos(tilt))
        guard p.z > 0.05 else { continue }
        let sx = center.x + p.x * r, sy = center.y + p.y * r
        let size = r * 0.085
        let len = hypot(p.x, p.y)
        let angle = atan2(p.y, p.x)
        ctx.saveGState()
        ctx.translateBy(x: sx, y: sy)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: max(0.25, p.z), y: 1)
        let shade = 0.10 + 0.12 * (1 - p.z) + 0.05 * len
        ctx.setFillColor(rgb(0x5E6870, shade).cg)
        ctx.fillEllipse(in: CGRect(x: -size, y: -size, width: size * 2, height: size * 2))
        ctx.setFillColor(rgb(0xFFFFFF, 0.22 * p.z).cg)
        ctx.fillEllipse(in: CGRect(x: -size * 0.2, y: -size * 0.75, width: size * 1.1, height: size * 1.1))
        ctx.restoreGState()
    }
    // Shading pass over the dimples, then the rim light and specular.
    radial(ctx, [(0, rgb(0xFFFFFF, 0)), (0.7, rgb(0x0B1418, 0.05)), (1, rgb(0x0B1418, 0.45))],
           center: center, radius: r, from: light)
    // Warm rim light from the floodlit horizon: a crescent on the lower right.
    radial(ctx, [(0, ember.alpha(0.7)), (0.45, ember.alpha(0.28)), (1, ember.alpha(0))],
           center: CGPoint(x: center.x + r * 0.95, y: center.y + r * 0.55), radius: r * 1.05)
    radial(ctx, [(0, rgb(0xFFFFFF, 0.9)), (1, rgb(0xFFFFFF, 0))],
           center: CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.45), radius: r * 0.32, scaleY: 0.7)
    ctx.restoreGState()
}

/// The app's ball-lock brackets: four corners around the ball.
func brackets(_ c: Canvas, center: CGPoint, half: CGFloat, corner: CGFloat, thickness: CGFloat, color: RGB = ion) {
    func path(_ g: CGContext) {
        g.setLineCap(.round)
        g.setLineJoin(.round)
        g.setLineWidth(thickness)
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] as [(CGFloat, CGFloat)] {
            let x = center.x + sx * half, y = center.y + sy * half
            g.move(to: CGPoint(x: x, y: y - sy * corner))
            g.addLine(to: CGPoint(x: x, y: y))
            g.addLine(to: CGPoint(x: x - sx * corner, y: y))
        }
        g.strokePath()
    }
    c.glow(radius: thickness * 2.2, intensity: 1) { g in
        g.setStrokeColor(color.alpha(0.9).cg)
        path(g)
    }
    c.ctx.setStrokeColor(color.cg)
    path(c.ctx)
    c.ctx.setStrokeColor(rgb(0xE9FFF4, 0.6).cg)
    c.ctx.saveGState()
    path(c.ctx) // second pass, thinner core
    c.ctx.restoreGState()
}

/// A tapered ball-flight tracer with a hot core and a wide glow.
func tracerArc(_ c: Canvas, _ curve: Cubic, startWidth: CGFloat, endWidth: CGFloat, scale s: CGFloat) {
    let samples = 160
    func taper(_ g: CGContext, widthScale: CGFloat, colors: (RGB, RGB)) {
        g.setLineCap(.round)
        for i in 0..<samples {
            let t0 = CGFloat(i) / CGFloat(samples), t1 = CGFloat(i + 1) / CGFloat(samples)
            // Thin at the very start (leaving the ball), widest early, thin at landing.
            let ramp = min(1, t0 / 0.06)
            let width = (startWidth + (endWidth - startWidth) * pow(t0, 0.8)) * (0.35 + 0.65 * ramp) * widthScale
            let mix = pow(t0, 0.7)
            let col = RGB(r: colors.0.r + (colors.1.r - colors.0.r) * mix,
                          g: colors.0.g + (colors.1.g - colors.0.g) * mix,
                          b: colors.0.b + (colors.1.b - colors.0.b) * mix,
                          a: colors.0.a + (colors.1.a - colors.0.a) * mix)
            g.setStrokeColor(col.cg)
            g.setLineWidth(width)
            g.move(to: curve.point(t0))
            g.addLine(to: curve.point(t1))
            g.strokePath()
        }
    }
    c.glow(radius: 34 * s, intensity: 1) { g in taper(g, widthScale: 3.2, colors: (plasma.alpha(0.9), ember.alpha(0.55))) }
    c.glow(radius: 10 * s, intensity: 1) { g in taper(g, widthScale: 1.6, colors: (plasma, tracer.alpha(0.9))) }
    taper(c.ctx, widthScale: 1, colors: (ember, tracer))
    taper(c.ctx, widthScale: 0.4, colors: (tracer, rgb(0xFFFFFF)))
    // Landing flash.
    let end = curve.p3
    c.glow(radius: 18 * s, intensity: 1) { g in
        radial(g, [(0, tracer), (1, tracer.alpha(0))], center: end, radius: 34 * s)
    }
    c.ctx.setStrokeColor(tracer.alpha(0.55).cg)
    c.ctx.setLineWidth(2.5 * s)
    c.ctx.strokeEllipse(in: CGRect(x: end.x - 40 * s, y: end.y - 9 * s, width: 80 * s, height: 18 * s))
}

func vignette(_ c: Canvas, strength: CGFloat) {
    radial(c.ctx, [(0, rgb(0x000000, 0)), (0.65, rgb(0x000000, 0)), (1, rgb(0x000000, strength))],
           center: CGPoint(x: c.w / 2, y: c.h / 2), radius: hypot(c.w, c.h) / 2)
}

func text(_ c: Canvas, _ runs: [(String, RGB)], size: CGFloat, weight: NSFont.Weight, width: NSFont.Width,
          kern: CGFloat, centerX: CGFloat, baseline: CGFloat, glowColor: RGB? = nil) {
    let font = NSFont.systemFont(ofSize: size, weight: weight, width: width)
    let attributed = NSMutableAttributedString()
    for (string, color) in runs {
        attributed.append(NSAttributedString(string: string, attributes: [
            .font: font, .kern: kern,
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a),
        ]))
    }
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    func draw(_ g: CGContext) {
        g.saveGState()
        g.translateBy(x: centerX - bounds.width / 2 - bounds.minX, y: baseline)
        g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero
        CTLineDraw(line, g)
        g.restoreGState()
    }
    if glowColor != nil { c.glow(radius: size * 0.35, intensity: 0.6) { draw($0) } }
    draw(c.ctx)
}

// MARK: - Compositions

/// Icons: `round` lays it out for the watch's circular mask.
func icon(round: Bool) -> CGImage {
    let c = Canvas(1024, 1024)
    let s: CGFloat = 1
    let horizon: CGFloat = round ? 590 : 610
    c.ctx.setFillColor(void.cg)
    c.ctx.fill(CGRect(x: 0, y: 0, width: c.w, height: c.h))
    sky(c, horizon: horizon, lights: round ? [CGPoint(x: 205, y: 470), CGPoint(x: 640, y: 505)]
                                            : [CGPoint(x: 110, y: 470), CGPoint(x: 640, y: 505)], scale: s)
    turf(c, horizon: horizon, vanishX: 600, scale: s)

    let ballCenter = round ? CGPoint(x: 395, y: 680) : CGPoint(x: 345, y: 718)
    let r: CGFloat = round ? 118 : 132
    let flight = round
        ? Cubic(p0: CGPoint(x: ballCenter.x + r * 0.2, y: ballCenter.y - r * 0.35),
                c1: CGPoint(x: 520, y: 180), c2: CGPoint(x: 735, y: 140), p3: CGPoint(x: 820, y: horizon - 4))
        : Cubic(p0: CGPoint(x: ballCenter.x + r * 0.2, y: ballCenter.y - r * 0.35),
                c1: CGPoint(x: 500, y: 150), c2: CGPoint(x: 800, y: 90), p3: CGPoint(x: 905, y: horizon - 4))
    tracerArc(c, flight, startWidth: 34, endWidth: 9, scale: s)
    ball(c, center: ballCenter, radius: r)
    brackets(c, center: ballCenter, half: r * 1.42, corner: r * 0.5, thickness: r * 0.085)
    vignette(c, strength: round ? 0.55 : 0.45)
    return c.image()
}

/// Splash geometry, as fractions of the artwork (mirrored in SplashView).
enum SplashGeometry {
    static let size = CGSize(width: 1179, height: 2556)
    static let horizon: CGFloat = 0.60
    static let ball = CGPoint(x: 0.30, y: 0.712)
    static let ballRadius: CGFloat = 0.088 // × width
}

func splash() -> CGImage {
    let c = Canvas(Int(SplashGeometry.size.width), Int(SplashGeometry.size.height))
    let s: CGFloat = 1.6
    let horizon = c.h * SplashGeometry.horizon
    c.ctx.setFillColor(void.cg)
    c.ctx.fill(CGRect(x: 0, y: 0, width: c.w, height: c.h))
    sky(c, horizon: horizon, lights: [CGPoint(x: c.w * 0.08, y: horizon - 150), CGPoint(x: c.w * 0.64, y: horizon - 110),
                                      CGPoint(x: c.w * 0.93, y: horizon - 170)], scale: s)
    turf(c, horizon: horizon, vanishX: c.w * 0.62, scale: s)
    let center = CGPoint(x: c.w * SplashGeometry.ball.x, y: c.h * SplashGeometry.ball.y)
    ball(c, center: center, radius: c.w * SplashGeometry.ballRadius)

    text(c, [("GOLF", floodlight), ("MONITOR", plasma)], size: 112, weight: .black, width: .expanded,
         kern: 2, centerX: c.w / 2, baseline: c.h * 0.205, glowColor: plasma)
    // Accent rule + tagline.
    let ruleY = c.h * 0.205 + 58
    c.ctx.saveGState()
    c.ctx.clip(to: CGRect(x: c.w * 0.38, y: ruleY, width: c.w * 0.24, height: 4))
    linear(c.ctx, [(0, plasma.alpha(0)), (0.5, plasma), (1, plasma.alpha(0))],
           from: CGPoint(x: c.w * 0.38, y: 0), to: CGPoint(x: c.w * 0.62, y: 0))
    c.ctx.restoreGState()
    text(c, [("THE RANGE, REIMAGINED", tracer.alpha(0.85))], size: 34, weight: .semibold, width: .expanded,
         kern: 9, centerX: c.w / 2, baseline: ruleY + 78)
    vignette(c, strength: 0.5)
    return c.image()
}

// MARK: - Output

func writePNG(_ image: CGImage, to path: String, opaque: Bool) {
    var out = image
    if opaque {
        let flat = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        flat.setFillColor(void.cg)
        flat.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        flat.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        out = flat.makeImage()!
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path) (\(out.width)×\(out.height))")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let outDir = CommandLine.arguments.dropFirst().first
func target(_ assetPath: String, preview: String) -> String {
    outDir.map { "\($0)/\(preview)" } ?? "\(root)/\(assetPath)"
}

writePNG(icon(round: false), to: target("GolfMonitor/Assets.xcassets/AppIcon.appiconset/Icon-1024.png",
                                        preview: "icon-ios.png"), opaque: true)
writePNG(icon(round: true), to: target("GolfMonitorWatch/Assets.xcassets/AppIcon.appiconset/Icon-1024.png",
                                       preview: "icon-watch.png"), opaque: true)
writePNG(splash(), to: target("GolfMonitor/Assets.xcassets/GolfMonitorSplash.imageset/GolfMonitorSplash.png",
                              preview: "splash.png"), opaque: true)
