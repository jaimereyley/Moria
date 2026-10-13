// swift Assets.swift Door.png <dir> — writes what actool compiles into Moria.app:
// - AppIcon.icon, the icon in Icon Composer's format: the ink of Door.png as glowing Spindrift on black, full bleed.
//   macOS masks it to its rounded square itself; an old-style .icns would instead be shrunk onto a light plate.
// - Assets.xcassets with AccentColor, Spindrift, which the app's own glow and the system's accents both use.
import AppKit
import CoreImage

let door = CIImage(contentsOf: URL(filePath: CommandLine.arguments[1]))!
let dir = URL(filePath: CommandLine.arguments[2]), icon = dir.appending(path: "AppIcon.icon")
let (red, green, blue) = (0.451, 0.988, 0.838)  // Apple's Spindrift crayon
let side = 1024.0, square = CGRect(x: 0, y: 0, width: side, height: side)

/// The ink in `color`, centred on the square.
func ink(_ color: CIColor) -> CIImage {
    let mask = door.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.76 * side / door.extent.height])
    let placed = mask.transformed(by: CGAffineTransform(translationX: (side - mask.extent.width) / 2, y: (side - mask.extent.height) / 2 - 10))
    return CIImage(color: color).cropped(to: placed.extent).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: placed])
}

// Glowing paint: a wide bloom and a tight halo of Spindrift around strokes that burn a shade whiter.
let paint = ink(CIColor(red: red, green: green, blue: blue))
let layers = [paint.applyingGaussianBlur(sigma: 30), paint.applyingGaussianBlur(sigma: 8), paint, ink(CIColor(red: 0.3, green: 0.15, blue: 0.2))]
let lit = layers.reduce(CIImage(color: .black).cropped(to: square)) {
    $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0])
}

try? FileManager.default.removeItem(at: icon)
try FileManager.default.createDirectory(at: icon.appending(path: "Assets"), withIntermediateDirectories: true)
try NSBitmapImageRep(cgImage: CIContext().createCGImage(lit.cropped(to: square), from: square)!)
    .representation(using: .png, properties: [:])!.write(to: icon.appending(path: "Assets/Door.png"))
// No glass: the door should glow, not shine.
try #"""
{
  "fill" : { "solid" : "srgb:0.00000,0.00000,0.00000,1.00000" },
  "groups" : [ { "layers" : [ { "glass" : false, "image-name" : "Door.png", "name" : "Door" } ] } ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""#.write(to: icon.appending(path: "icon.json"), atomically: true, encoding: .utf8)

let accent = dir.appending(path: "Assets.xcassets/AccentColor.colorset")
try FileManager.default.createDirectory(at: accent, withIntermediateDirectories: true)
try """
{
  "colors" : [ { "idiom" : "universal", "color" : { "color-space" : "srgb", "components" : { "red" : "\(red)", "green" : "\(green)", "blue" : "\(blue)", "alpha" : "1.000" } } } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: accent.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
