import AppKit
import SwiftUI

/// A folder of per-mood images: idle, working, waiting, happy, sad, sleeping (.png, .gif, .jpg, .heic).
/// Missing moods fall back to idle; an optional skin.json `{ "motion": false }` turns off the bounce/tilt.
/// A folder holding a Codex Pet package (pet.json + spritesheet) is played as a sprite atlas instead.
struct Skin {
    static let moodFiles: [(PetMood, String)] = [
        (.idle, "idle"), (.working, "working"), (.waiting, "waiting"),
        (.happy, "happy"), (.sad, "sad"), (.sleeping, "sleeping"),
    ]
    private static let extensions = ["gif", "png", "jpg", "jpeg", "heic", "webp"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaseoPet/Skins", isDirectory: true)
    }

    let name: String
    let motion: Bool
    private var images: [PetMood: NSImage] = [:]
    private var frames: [PetMood: [NSImage]] = [:]

    var isSprite: Bool { !frames.isEmpty }

    func image(for mood: PetMood, at time: Double = 0) -> NSImage? {
        if let sequence = frames[mood] ?? frames[.idle], !sequence.isEmpty {
            let fps = mood == .sleeping ? 3.0 : 8.0
            return sequence[Int(time * fps) % sequence.count]
        }
        return images[mood] ?? images[.idle]
    }

    static func available() -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    static func load(_ name: String) -> Skin? {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        if let sprite = CodexPet.load(folder: folder, name: name) {
            return sprite
        }
        var images: [PetMood: NSImage] = [:]
        for (mood, base) in moodFiles {
            for ext in extensions {
                let url = folder.appendingPathComponent("\(base).\(ext)")
                if let image = NSImage(contentsOf: url) {
                    images[mood] = image
                    break
                }
            }
        }
        guard images[.idle] != nil || !images.isEmpty else { return nil }
        if images[.idle] == nil, let any = images.values.first {
            images[.idle] = any
        }
        var motion = true
        if let data = try? Data(contentsOf: folder.appendingPathComponent("skin.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let flag = json["motion"] as? Bool {
            motion = flag
        }
        return Skin(name: name, motion: motion, images: images)
    }

    fileprivate init(name: String, motion: Bool, images: [PetMood: NSImage] = [:], frames: [PetMood: [NSImage]] = [:]) {
        self.name = name
        self.motion = motion
        self.images = images
        self.frames = frames
    }
}

/// Codex Pet atlas (https://codex-pets.net): 8 columns; 9 rows, or 11 with look-around rows.
enum CodexPet {
    // Row order and frame counts of the Codex Pet format.
    private static let rows: [(id: String, frames: Int)] = [
        ("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5),
        ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6),
    ]
    private static let moodRows: [PetMood: String] = [
        .idle: "idle", .sleeping: "idle", .working: "running", .waiting: "waiting",
        .happy: "jumping", .sad: "failed",
    ]

    static func load(folder: URL, name: String) -> Skin? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pet.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let sheetName = manifest["spritesheetPath"] as? String ?? "spritesheet.webp"
        guard let sheet = NSImage(contentsOf: folder.appendingPathComponent(sheetName)),
              let atlas = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let cellWidth = atlas.width / 8
        // 192x192 cells give 9 rows in 1728px; the 192x208 variant has 9 or 11 rows.
        let rowCount = [11, 9].first { count in
            let height = atlas.height / count
            return atlas.height % count == 0 && (height == cellWidth || height == cellWidth * 13 / 12)
        } ?? 9
        let cellHeight = atlas.height / rowCount

        var frames: [PetMood: [NSImage]] = [:]
        for (mood, rowId) in moodRows {
            guard let row = rows.firstIndex(where: { $0.id == rowId }) else { continue }
            frames[mood] = (0..<rows[row].frames).compactMap { column in
                let rect = CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)
                return atlas.cropping(to: rect).map { NSImage(cgImage: $0, size: NSSize(width: cellWidth, height: cellHeight)) }
            }
        }
        let display = manifest["displayName"] as? String ?? name
        return Skin(name: display, motion: false, frames: frames)
    }

    /// Downloads a pet from a codex-pets.net page URL (…/#/pets/<id>) or a bare id into the skins folder.
    static func install(from input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.components(separatedBy: "/").last { !$0.isEmpty } ?? trimmed
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = URL(string: "https://codex-pets.net/api/pets/\(id)/download")!
        let (zip, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.fileDoesNotExist)
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("paseo-pet-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("pet.zip")
        try zip.write(to: archive)

        let target = Skin.directory.appendingPathComponent(id, isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.appendingPathComponent("out").path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        // Some packages wrap files in a folder; take the directory that holds pet.json.
        let out = staging.appendingPathComponent("out")
        let enumerator = fm.enumerator(at: out, includingPropertiesForKeys: nil)
        var source = out
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent == "pet.json" {
                source = file.deletingLastPathComponent()
                break
            }
        }
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: Skin.directory, withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: target)
        guard CodexPet.load(folder: target, name: id) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return id
    }
}

/// NSImageView plays animated GIFs; SwiftUI's Image does not.
struct SkinImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image {
            view.image = image
        }
    }
}
