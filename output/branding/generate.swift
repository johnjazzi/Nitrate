import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let palette: [(CGFloat, String)] = [(-36, "#FF4D22"), (36, "#8010E8"), (0, "#FFAA32")]
let radius: CGFloat = 340
let holes: [(CGFloat, CGFloat)] = (0..<5).map { i in
    let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * CGFloat.pi / 5
    return (cos(a) * 169, sin(a) * 169)
}
func shape() -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius*2, height: radius*2))
    for (x, y) in holes { p.addEllipse(in: CGRect(x: x-78, y: y-78, width: 156, height: 156)) }
    return p
}
func color(_ hex: String) -> CGColor {
    let n = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(red: CGFloat((n >> 16)&255)/255, green: CGFloat((n >> 8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1)
}
func export(_ name: String, width: Int, height: Int, scale: CGFloat) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.translateBy(x: CGFloat(width)/2, y: CGFloat(height)/2)
    ctx.scaleBy(x: scale, y: -scale)
    for (offset, hex) in palette {
        ctx.saveGState()
        ctx.translateBy(x: offset, y: 0)
        ctx.addPath(shape())
        ctx.setAlpha(offset == 0 ? 1 : 0.8)
        ctx.setFillColor(color(hex))
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> String {
        "M \(x-r) \(y) a \(r) \(r) 0 1 0 \(2*r) 0 a \(r) \(r) 0 1 0 \(-2*r) 0 Z"
    }
    let d = ([circle(0, 0, radius)] + holes.map { circle($0.0, $0.1, 78) }).joined(separator: " ")
    let layers = palette.map { "<path transform=\"translate(\($0.0) 0)\" fill=\"\($0.1)\" fill-opacity=\"\($0.0 == 0 ? 1.0 : 0.8)\" fill-rule=\"evenodd\" d=\"\(d)\"/>" }.joined(separator: "\n")
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
    <rect width="100%" height="100%" fill="#000000"/>
    <g transform="translate(\(width/2) \(height/2)) scale(\(scale))">
    \(layers)
    </g>
    </svg>
    """
    try svg.write(to: root.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
}
try export("app-icon", width: 1024, height: 1024, scale: 1)
try export("splash-screen", width: 1290, height: 2796, scale: 0.62)
try export("preview", width: 512, height: 512, scale: 0.5)
print("Saved app-icon, splash-screen, and preview PNG/SVG assets.")
