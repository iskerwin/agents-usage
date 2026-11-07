import AgentsUsageKit
import Foundation

// Writes an .iconset for iconutil into the directory given.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        guard let png = AppMark.appIconPNG(pixels: points * scale) else { exit(1) }
        try png.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
