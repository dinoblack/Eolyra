// Uso: render <entrada.svg> <saida.png> <px>   |   render --sheet <saida.png> <px> a.svg b.svg ...
import AppKit
func draw(_ path: String, _ px: Int, into ctx: NSGraphicsContext, at rect: NSRect) {
    guard let img = NSImage(contentsOfFile: path) else { fatalError("svg inválido: \(path)") }
    NSGraphicsContext.current = ctx
    img.draw(in: rect)
}
func png(_ w: Int, _ h: Int, bg: NSColor? = nil, _ body: (NSGraphicsContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    if let bg { bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill() }
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let a = CommandLine.arguments
if a[1] == "--sheet" {
    let px = Int(a[3])!, files = Array(a[4...]), pad = 40
    let data = png(files.count * (px + pad) + pad, px + 2 * pad, bg: NSColor(white: 0.93, alpha: 1)) { ctx in
        for (i, f) in files.enumerated() { draw(f, px, into: ctx, at: NSRect(x: pad + i * (px + pad), y: pad, width: px, height: px)) }
    }
    try! data.write(to: URL(fileURLWithPath: a[2]))
} else {
    let px = Int(a[3])!
    try! png(px, px) { ctx in draw(a[1], px, into: ctx, at: NSRect(x: 0, y: 0, width: px, height: px)) }
        .write(to: URL(fileURLWithPath: a[2]))
}
