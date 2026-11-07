import CoreGraphics
import CoreImage
import Foundation

/// A parsed 3D .cube LUT, ready to apply as a Core Image colour cube.
struct CubeLUT {
    let size: Int
    let rgba: [Float]   // size³ entries of RGBA (alpha 1), red varying fastest — matches CIColorCube

    /// Parses a .cube file. Supports 3D LUTs (LUT_3D_SIZE). Returns nil if it isn't a usable 3D LUT.
    static func parse(_ text: String) -> CubeLUT? {
        var size = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        values.reserveCapacity(1 << 16)

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword.uppercased() {
            case "LUT_3D_SIZE": size = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            case "LUT_1D_SIZE": return nil   // 1D LUTs aren't supported
            case "DOMAIN_MIN": if parts.count >= 4 { domainMin = parts[1...3].compactMap { Float($0) } }
            case "DOMAIN_MAX": if parts.count >= 4 { domainMax = parts[1...3].compactMap { Float($0) } }
            case "TITLE": continue
            default:
                // A data line: three floats.
                if parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                    values.append(r); values.append(g); values.append(b)
                }
            }
        }

        guard size >= 2, size <= 128, values.count == size * size * size * 3 else { return nil }

        // Normalise into 0…1 if the file declared a wider domain, then pack as RGBA.
        let span: [Float] = [max(1e-6, domainMax[0] - domainMin[0]),
                             max(1e-6, domainMax[1] - domainMin[1]),
                             max(1e-6, domainMax[2] - domainMin[2])]
        var rgba = [Float](repeating: 1, count: size * size * size * 4)
        var src = 0, dst = 0
        while src < values.count {
            rgba[dst] = min(1, max(0, (values[src] - domainMin[0]) / span[0]))
            rgba[dst + 1] = min(1, max(0, (values[src + 1] - domainMin[1]) / span[1]))
            rgba[dst + 2] = min(1, max(0, (values[src + 2] - domainMin[2]) / span[2]))
            rgba[dst + 3] = 1
            src += 3; dst += 4
        }
        return CubeLUT(size: size, rgba: rgba)
    }

    func apply(_ image: CIImage) -> CIImage {
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data,
            "inputColorSpace": space,
        ])
    }
}

/// Imported .cube LUTs, kept as files and surfaced as extra looks in the editor.
enum LUTStore {
    private(set) static var looks: [Look] = load()

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func id(for name: String) -> String { "lut:" + name }

    /// Copies a picked .cube into the LUTs folder (after checking it parses). Returns the new look's id.
    @discardableResult
    static func importLUT(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard CubeLUT.parse(text) != nil else {
            throw NSError(domain: "Lumen", code: 1, userInfo: [NSLocalizedDescriptionKey: "That isn't a 3D .cube LUT Lumen can read."])
        }
        let name = url.deletingPathExtension().lastPathComponent
        let dest = folder.appendingPathComponent(name).appendingPathExtension("cube")
        try? FileManager.default.removeItem(at: dest)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        reload()
        return id(for: name)
    }

    static func delete(id lookID: String) {
        guard lookID.hasPrefix("lut:") else { return }
        let name = String(lookID.dropFirst("lut:".count))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name).appendingPathExtension("cube"))
        reload()
    }

    static func isCustom(_ lookID: String) -> Bool { lookID.hasPrefix("lut:") }

    static func reload() { looks = load() }

    private static func load() -> [Look] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            .compactMap { file -> Look? in
                guard let text = try? String(contentsOf: file, encoding: .utf8), let cube = CubeLUT.parse(text) else { return nil }
                let name = file.deletingPathExtension().lastPathComponent
                return Look(id: id(for: name), name: name) { cube.apply($0).cropped(to: $0.extent) }
            }
    }
}
