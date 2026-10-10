import Foundation

struct SnapshotEntry: Identifiable, Equatable {
    let url: URL
    let modifiedAt: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum SnapshotReadError: Error {
    case outsideFolder, unsupportedFile, tooLarge
}

enum SnapshotStore {
    static let maximumBytes = 16 * 1024 * 1024

    private static func folder(_ project: URL) throws -> URL {
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("local/diagnostics", isDirectory: true).standardizedFileURL
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw SnapshotReadError.outsideFolder }
        return directory
    }

    static func entries(project: URL, limit: Int = 50) throws -> [SnapshotEntry] {
        let directory = try folder(project)
        if !FileManager.default.fileExists(atPath: directory.path) { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        return urls.compactMap { url -> SnapshotEntry? in
            let candidate = url.absoluteURL.standardizedFileURL
            guard candidate.pathExtension == "json", candidate.resolvingSymlinksInPath().path == candidate.path,
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes <= maximumBytes,
                  let date = values.contentModificationDate else { return nil }
            return SnapshotEntry(url: candidate, modifiedAt: date)
        }.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.name < $1.name }
            return $0.modifiedAt > $1.modifiedAt
        }.prefix(max(0, min(limit, 50))).map { $0 }
    }

    static func load(_ url: URL, project: URL) throws -> SnapshotSummary {
        let directory = try folder(project)
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directory.path,
              candidate.resolvingSymlinksInPath().path == candidate.path else { throw SnapshotReadError.outsideFolder }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard candidate.pathExtension == "json", values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SnapshotReadError.unsupportedFile
        }
        guard let bytes = values.fileSize, bytes <= maximumBytes else { throw SnapshotReadError.tooLarge }
        // Read only the selected file, with a hard bound even if it grows after stat.
        let handle = try FileHandle(forReadingFrom: candidate)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw SnapshotReadError.tooLarge }
        return try SnapshotSummary(contents: data)
    }
}

struct SnapshotDifference: Identifiable, Equatable {
    let id: String
    let title: String
    let before: String
    let after: String
}

func compareSnapshots(_ before: SnapshotSummary, _ after: SnapshotSummary) -> [SnapshotDifference] {
    var differences: [SnapshotDifference] = []
    if let left = before.availableMemoryKiB, let right = after.availableMemoryKiB, left != right {
        differences.append(SnapshotDifference(id: "memory", title: "Доступная RAM, КиБ",
                                              before: String(left), after: String(right)))
    }
    if let left = before.audioActive, let right = after.audioActive, left != right {
        differences.append(SnapshotDifference(id: "audio", title: "Активная аудиодорожка",
                                              before: left ? "Есть" : "Нет", after: right ? "Есть" : "Нет"))
    }
    if let left = before.mixerUnderruns, let right = after.mixerUnderruns, left != right {
        differences.append(SnapshotDifference(id: "underruns", title: "Счётчики mixer",
                                              before: left, after: right))
    }
    let leftValues = Dictionary(uniqueKeysWithValues: before.soundSettings.map { ($0.id, $0.value) })
    for setting in after.soundSettings {
        guard let left = leftValues[setting.id], left != setting.value else { continue }
        differences.append(SnapshotDifference(id: setting.id, title: setting.title,
                                              before: String(left), after: String(setting.value)))
    }
    return differences
}
