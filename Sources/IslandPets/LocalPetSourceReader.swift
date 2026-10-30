import Foundation
import CoreFoundation
import SQLite3
import IslandCore

public actor LocalPetSourceReader {
    private let environment: PetSourceEnvironment
    private var archives: [String: PetASARArchive] = [:]
    private var appearances: [ProviderID: ProviderPetAppearance] = [:]
    private var qoderIndexes: [String: [PetAnimationState: QoderAnimationPaths]] = [:]
    private var jsonCache: [String: (String, [String: Any])] = [:]
    private var codexAliasCache: (stamp: String, aliases: [String: String])?
    private var qoderCacheIDs: [String: (stamp: String, petID: String?)] = [:]

    public init(environment: PetSourceEnvironment = .live()) { self.environment = environment }

    public func read(_ provider: ProviderID) throws -> ProviderPetAppearance? {
        switch provider {
        case .qoder: return try readQoder()
        case .codex: return try readCodex()
        case .claude, .zcode, .dsh, .codebuddy, .workbuddy, .generic: return nil
        }
    }

    /// Reports whether the source application has its desktop pet enabled.
    /// This is intentionally separate from `read(_:)`, which continues to resolve artwork.
    public func isPetEnabled(_ provider: ProviderID) throws -> Bool {
        switch provider {
        case .qoder: return try qoderPetEnabled()
        case .codex: return try codexPetEnabled()
        case .claude, .zcode, .dsh, .codebuddy, .workbuddy, .generic: return false
        }
    }

    private func qoderPetEnabled() throws -> Bool {
        let file = environment.qoderDataURL.appendingPathComponent("main.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw PetSourceError.invalid("暂时无法只读访问 Qoder 灵宠设置")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value_json FROM app_settings WHERE setting_key = 'desktopPet.enabled' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw PetSourceError.invalid("Qoder 灵宠设置表暂时不可读")
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 64,
              let value = sqlite3_column_text(statement, 0),
              let number = (try? JSONSerialization.jsonObject(with: Data(String(cString: value).utf8), options: .fragmentsAllowed)) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            if result == SQLITE_ROW { return false }
            throw PetSourceError.invalid("Qoder 灵宠设置不可读")
        }
        return number.boolValue
    }

    private func codexPetEnabled() throws -> Bool {
        let config = environment.codexHomeURL.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: config.path) else { return false }
        let data: Data
        do { data = try petReadLimited(config, limit: PetLimits.manifest) }
        catch { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let settings = Self.desktopCodexSettings(in: text)
        if settings.visibilitySpecified { return settings.visible ?? false }
        return settings.hasSelectedAvatar
    }

    private static func desktopCodexSettings(in text: String) -> (visible: Bool?, visibilitySpecified: Bool, hasSelectedAvatar: Bool) {
        var inDesktop = false
        var visible: Bool?
        var visibilitySpecified = false
        var hasSelectedAvatar = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = stripTOMLComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.first == "[", let close = line.firstIndex(of: "]") {
                let name = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                inDesktop = unquoteTOML(name) == "desktop"
                continue
            }
            guard inDesktop, let equals = line.firstIndex(of: "=") else { continue }
            let key = unquoteTOML(String(line[..<equals]).trimmingCharacters(in: .whitespaces))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "avatar-overlay-pet-visible" {
                visibilitySpecified = true
                if value == "true" { visible = true }
                else if value == "false" { visible = false }
                else { visible = nil }
            } else if key == "selected-avatar-id", let id = parseTOMLString(value), !id.isEmpty {
                hasSelectedAvatar = true
            }
        }
        return (visible, visibilitySpecified, hasSelectedAvatar)
    }

    private static func stripTOMLComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let active = quote {
                if active == "\"", character == "\\", !escaped { escaped = true; continue }
                if character == active && !escaped { quote = nil }
                escaped = false
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(value[..<index]) }
        }
        return value
    }

    private static func unquoteTOML(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, value.last == first, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func parseTOMLString(_ value: String) -> String? {
        guard let first = value.first, first == "\"" || first == "'" else { return nil }
        if first == "'" {
            guard let end = value.dropFirst().firstIndex(of: "'") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end])
        }
        for index in value.indices.dropFirst() where value[index] == "\"" {
            let literal = String(value[...index])
            return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
        }
        return nil
    }

    private func json(at url: URL, limit: Int = PetLimits.manifest) throws -> (String, [String: Any]) {
        let stamp = try petFileStamp(url)
        if let cached = jsonCache[url.path], cached.0 == stamp { return cached }
        let value = try petJSON(petReadLimited(url, limit: limit))
        if jsonCache.count >= 12 { jsonCache.removeAll(keepingCapacity: true) }
        jsonCache[url.path] = (stamp, value)
        return (stamp, value)
    }

    private func archive(appNames: [String]) throws -> PetASARArchive? {
        var candidates: [URL] = []
        for directory in environment.appDirectories {
            if directory.pathExtension == "app" {
                if appNames.contains(directory.lastPathComponent) { candidates.append(directory) }
            } else {
                candidates += appNames.map { directory.appendingPathComponent($0, isDirectory: true) }
            }
        }
        for app in candidates {
            let file = app.appendingPathComponent("Contents/Resources/app.asar")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let stamp = try petFileStamp(file)
            if let cached = archives[file.path], cached.revision == stamp { return cached }
            let value = try PetASARArchive(url: file)
            archives[file.path] = value
            return value
        }
        return nil
    }

    private func sheetAppearance(provider: ProviderID, selection: String, displayName: String, revision: String, source: String, version: Int, load: () throws -> Data?) throws -> ProviderPetAppearance? {
        if let cached = appearances[provider], cached.revision == revision { return cached }
        guard let data = try load(), petIsImage(data) else { return nil }
        var animations: [PetAnimationState: PetAnimationResource] = [:]
        for state in PetAnimationState.allCases {
            animations[state] = .init(data: data, spriteLayout: .sheet(state, version: version))
        }
        let result = ProviderPetAppearance(selectionID: selection, displayName: displayName, revision: revision, sourceDescription: source, animations: animations)
        appearances[provider] = result
        return result
    }

    private func customSheet(provider: ProviderID, selection: String, directory: URL, manifestName: String, prefix: String, source: String) throws -> ProviderPetAppearance? {
        let manifest = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        let (manifestStamp, object) = try json(at: manifest)
        let imagePath = object["spritesheetPath"] as? String ?? (FileManager.default.fileExists(atPath: directory.appendingPathComponent("spritesheet.webp").path) ? "spritesheet.webp" : "spritesheet.png")
        let image = try petSafeChild(imagePath, under: directory)
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }
        let version = (object["spriteVersionNumber"] as? NSNumber)?.intValue ?? 1
        guard version == 1 || version == 2 else { return nil }
        let revision = prefix + "|" + selection + "|" + manifestStamp + "|" + (try petFileStamp(image))
        let name = object["displayName"] as? String ?? object["name"] as? String ?? object["id"] as? String ?? directory.lastPathComponent
        return try sheetAppearance(provider: provider, selection: selection, displayName: name, revision: revision, source: source, version: version) { try petReadLimited(image, limit: PetLimits.image) }
    }

    private func readCodex() throws -> ProviderPetAppearance? {
        let config = environment.codexHomeURL.appendingPathComponent("config.toml")
        var selection = "codex"
        let prefix = "codex"
        if FileManager.default.fileExists(atPath: config.path) {
            let data = try petReadLimited(config, limit: PetLimits.manifest)
            guard let text = String(data: data, encoding: .utf8) else { throw PetSourceError.invalid("Codex 配置不是 UTF-8") }
            selection = Self.selectedCodexAvatar(in: text) ?? "codex"
        }
        if selection.hasPrefix("pet_") {
            let global = environment.codexHomeURL.appendingPathComponent(".codex-global-state.json")
            guard FileManager.default.fileExists(atPath: global.path) else { return nil }
            let stamp = try petFileStamp(global)
            if codexAliasCache?.stamp != stamp {
                // Discard the global object immediately; retain only cloud ID -> local alias.
                // Do not cache unrelated app state or opaque account scope identifiers.
                let object = try petJSON(petReadLimited(global, limit: PetLimits.state))
                let persisted = object["electron-persisted-atom-state"] as? [String: Any]
                let scoped = persisted?["migrated-cloud-pet-ids-v1"] as? [String: Any] ?? [:]
                var aliases: [String: String] = [:]
                for scope in scoped.values {
                    guard let values = scope as? [String: Any] else { continue }
                    for (alias, value) in values where alias.hasPrefix("custom:") {
                        guard let cloud = value as? String, cloud.hasPrefix("pet_") else { continue }
                        if let previous = aliases[cloud] { aliases[cloud] = min(previous, alias) }
                        else { aliases[cloud] = alias }
                    }
                }
                codexAliasCache = (stamp, aliases)
            }
            guard let alias = codexAliasCache?.aliases[selection] else { return nil }
            return try codexCustom(selection: selection, alias: alias, prefix: prefix + "|" + alias, source: "Codex 当前选择对应的本地素材")
        }
        if selection.hasPrefix("custom:") {
            return try codexCustom(selection: selection, alias: selection, prefix: prefix, source: "Codex 本地宠物")
        }
        let builtin = Set(["codex", "dewey", "fireball", "hoots", "rocky", "seedy", "stacky", "bsod", "null-signal"])
        guard builtin.contains(selection), let archive = try archive(appNames: ["Codex.app", "ChatGPT.app"]) else { return nil }
        let directory = "webview/assets"
        let names = try archive.names(in: directory)
        let candidates = names.filter { name in
            name.hasPrefix(selection + "-spritesheet-v") && name.hasSuffix(".webp") && Self.matches(name, pattern: "^" + NSRegularExpression.escapedPattern(for: selection) + "-spritesheet-v[12]-[A-Za-z0-9_-]+\\.webp$")
        }.sorted { lhs, rhs in
            let lv = lhs.contains("-spritesheet-v2-"), rv = rhs.contains("-spritesheet-v2-")
            return lv == rv ? lhs < rhs : lv
        }
        guard let name = candidates.first else { return nil }
        let path = directory + "/" + name
        guard let stamp = try archive.resourceStamp(path) else { return nil }
        return try sheetAppearance(provider: .codex, selection: selection, displayName: selection.capitalized, revision: prefix + "|" + stamp, source: "Codex 内置宠物", version: name.contains("-v2-") ? 2 : 1) { try archive.read(path, limit: PetLimits.image) }
    }

    private func codexCustom(selection: String, alias: String, prefix: String, source: String) throws -> ProviderPetAppearance? {
        let slug = String(alias.dropFirst("custom:".count))
        // A pet identity is one directory name, never an arbitrary file-system path.
        guard !slug.isEmpty, slug != ".", slug != "..", !slug.contains("/"), !slug.contains("\\"), !slug.contains("\0") else { throw PetSourceError.invalid("Codex 宠物目录越界") }
        for (base, manifest) in [("pets", "pet.json"), ("avatars", "avatar.json")] {
            let directory = try petSafeChild(base + "/" + slug, under: environment.codexHomeURL)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest).path) {
                return try customSheet(provider: .codex, selection: selection, directory: directory, manifestName: manifest, prefix: prefix, source: source)
            }
        }
        return nil
    }

    static func selectedCodexAvatar(in text: String) -> String? {
        var inDesktop = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inDesktop = line.range(of: #"^\[(?:desktop|"desktop"|'desktop')\]\s*(?:#.*)?$"#, options: .regularExpression) != nil
                continue
            }
            guard inDesktop, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard key == "selected-avatar-id" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.first == "\"" {
                var escaped = false
                for index in value.indices.dropFirst() {
                    if value[index] == "\"" && !escaped {
                        let literal = String(value[...index])
                        return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
                    }
                    if value[index] == "\\" && !escaped { escaped = true } else { escaped = false }
                }
            } else if value.first == "'", let end = value.dropFirst().firstIndex(of: "'") { return String(value[value.index(after: value.startIndex)..<end]) }
            return nil
        }
        return nil
    }

    private static func matches(_ value: String, pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }

    private func qoderSelection() throws -> (String, String) {
        let file = environment.qoderDataURL.appendingPathComponent("main.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return ("qoduck", "qoder-default") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; throw PetSourceError.invalid("暂时无法只读访问 Qoder 宠物选择")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value_json, updated_at FROM app_settings WHERE setting_key = 'desktopPet.activePetId' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw PetSourceError.invalid("Qoder 宠物选择表暂时不可读") }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return ("qoduck", "qoder-default") }
        guard result == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 4096, let value = sqlite3_column_text(statement, 0) else { throw PetSourceError.invalid("Qoder 宠物选择不可读") }
        let text = String(cString: value)
        guard let selection = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? String else { throw PetSourceError.invalid("Qoder 宠物选择格式无效") }
        let updated = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        return (selection, selection + "|" + updated)
    }

    private func readQoder() throws -> ProviderPetAppearance? {
        let (selection, prefix) = try qoderSelection()
        if selection.hasPrefix("petdex:") { return try qoderCustom(selection: selection, prefix: prefix) }
        guard selection == "qoduck" || selection == "kleidisDog", let archive = try archive(appNames: ["Qoder CN.app"]) else { return nil }
        return try qoderBuiltin(selection: selection, prefix: prefix, archive: archive)
    }

    private func qoderCustom(selection: String, prefix: String) throws -> ProviderPetAppearance? {
        let cache = environment.qoderDataURL.appendingPathComponent("desktop-pet-assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: cache.path) {
            let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { Self.matches($0.lastPathComponent, pattern: "^petdex-appearance-v1-[A-Za-z0-9_-]+\\.json$") }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            // The source may retain historical appearances. Bound work even for an unusually large cache.
            for file in files.prefix(128) {
                // Historical/broken cache entries must not prevent the current selection.
                // Retain only their tiny identity index, never every historical base64 image.
                guard let safeFile = try? petSafeChild(file.lastPathComponent, under: cache), let stamp = try? petFileStamp(safeFile) else { continue }
                if let indexed = qoderCacheIDs[safeFile.path], indexed.stamp == stamp, indexed.petID != selection { continue }
                let object: [String: Any]
                if let cached = jsonCache[safeFile.path], cached.0 == stamp { object = cached.1 }
                else {
                    guard let data = try? petReadLimited(safeFile, limit: PetLimits.cache), let decoded = try? petJSON(data) else {
                        qoderCacheIDs[safeFile.path] = (stamp, nil); continue
                    }
                    object = decoded
                }
                let petID = object["petId"] as? String
                qoderCacheIDs[safeFile.path] = (stamp, petID)
                guard petID == selection, let set = object["animationSet"] as? [String: Any] else { continue }
                // JSON here contains only pet artwork. Keep at most the selected compiled appearance.
                for old in jsonCache.keys.filter({ $0.hasPrefix(cache.path + "/") && $0 != safeFile.path }) { jsonCache.removeValue(forKey: old) }
                jsonCache[safeFile.path] = (stamp, object)
                let revision = prefix + "|" + stamp
                if let cached = appearances[.qoder], cached.revision == revision { return cached }
                var animations: [PetAnimationState: PetAnimationResource] = [:]
                for state in PetAnimationState.allCases {
                    guard let item = set[state.rawValue] as? [String: Any], let src = item["animatedSrc"] as? String, let data = try? Self.webPDataURL(src) else { continue }
                    let still = (item["stillSrc"] as? String).flatMap { try? Self.webPDataURL($0) }
                    animations[state] = .init(data: data, stillData: still)
                }
                guard animations[.idle] != nil else { continue }
                let result = ProviderPetAppearance(selectionID: selection, displayName: object["displayName"] as? String ?? selection, revision: revision, sourceDescription: "Qoder CN 当前宠物缓存", animations: animations)
                appearances[.qoder] = result
                return result
            }
        }
        let slug = String(selection.dropFirst("petdex:".count))
        guard !slug.isEmpty, slug != ".", slug != "..", !slug.contains("/"), !slug.contains("\\") else { throw PetSourceError.invalid("Petdex 宠物目录越界") }
        let root = environment.homeURL.appendingPathComponent(".petdex/pets", isDirectory: true)
        let directory = try petSafeChild(slug, under: root)
        return try customSheet(provider: .qoder, selection: selection, directory: directory, manifestName: "pet.json", prefix: prefix, source: "Qoder CN 当前 Petdex 本地素材")
    }

    private static func webPDataURL(_ value: String) throws -> Data? {
        let prefix = "data:image/webp;base64,"
        guard value.hasPrefix(prefix) else { return nil }
        guard value.utf8.count <= PetLimits.image * 4 / 3 + 100 else { throw PetSourceError.invalid("宠物内嵌素材超过大小限制") }
        guard let data = Data(base64Encoded: String(value.dropFirst(prefix.count))), data.count <= PetLimits.image, petIsImage(data) else { throw PetSourceError.invalid("宠物内嵌素材不是有效的 WebP 数据") }
        return data
    }
}

extension LocalPetSourceReader {
    private struct QoderAnimationPaths {
        var animated: String
        var still: String
    }

    private func qoderBuiltin(selection: String, prefix: String, archive: PetASARArchive) throws -> ProviderPetAppearance? {
        let directory = "out/renderer/assets"
        let known: [String: [PetAnimationState: QoderAnimationPaths]] = [
            "qoduck": [
                .idle: .init(animated: "idle-CQ1kV_ci.webp", still: "idle-still-CxxUmdSF.webp"),
                .running: .init(animated: "running-DhjlRvpK.webp", still: "running-still-D3n27TA5.webp"),
                .waiting: .init(animated: "waiting-GFVosEcH.webp", still: "waiting-still-CHI67WZK.webp"),
                .review: .init(animated: "review-DUTVSCZ_.webp", still: "review-still-D8bWXUHD.webp"),
                .failed: .init(animated: "failed-6XD83GqD.webp", still: "failed-still-Dx6RREsS.webp")
            ],
            "kleidisDog": [
                .idle: .init(animated: "idle-d24xaeJo.webp", still: "idle-still-pQaYwoLe.webp"),
                .running: .init(animated: "running-BqtGFDyu.webp", still: "running-still-z2tKxgpY.webp"),
                .waiting: .init(animated: "waiting-DO1hEa_Y.webp", still: "waiting-still-FcYseAfq.webp"),
                .review: .init(animated: "review-Dc0cR2By.webp", still: "review-still-C6Z_UYWw.webp"),
                .failed: .init(animated: "failed-D9fMMBN9.webp", still: "failed-still-COqCfv4i.webp")
            ]
        ]
        // Installed versions can change Vite hashes. Cache the restricted animation-table
        // lookup for the lifetime of this archive; do not rescan JS on every status tick.
        let paths: [PetAnimationState: QoderAnimationPaths]
        let key = "qoder-animation-index|" + selection + "|" + archive.revision
        if let cached = qoderIndexes[key] { paths = cached }
        else if let fixed = known[selection], try fixed.values.allSatisfy({ try archive.resourceStamp(directory + "/" + $0.animated) != nil && archive.resourceStamp(directory + "/" + $0.still) != nil }) {
            paths = fixed; qoderIndexes[key] = fixed
        } else {
            var candidates: [[PetAnimationState: QoderAnimationPaths]] = []
            var scannedBytes = 0
            let names = try archive.names(in: directory).filter { $0.hasSuffix(".js") }
            for name in names.prefix(2048) {
                guard let data = try? archive.read(directory + "/" + name, limit: 4 * PetLimits.manifest), !data.isEmpty else { continue }
                scannedBytes += data.count
                if scannedBytes > 32 * 1024 * 1024 { break }
                guard let text = String(data: data, encoding: .utf8), text.contains("animatedSrc:"), text.contains("stillSrc:"),
                      let candidate = Self.qoderAnimationTable(in: text) else { continue }
                let isDuck = text.contains("defaultDesktopPetAnimationSet")
                // The bundled dog table has no semantic pet identifier. Only its verified
                // module can identify it safely; unknown tables must fall back to the app icon.
                let isDog = !isDuck && name == "amkOvibw.js"
                guard (selection == "qoduck" && isDuck) || (selection == "kleidisDog" && isDog) else { continue }
                candidates.append(candidate)
            }
            // Multiple unidentified tables must not silently select another pet.
            guard candidates.count == 1, let found = candidates.first else { return nil }
            paths = found
            if qoderIndexes.count > 8 { qoderIndexes.removeAll() }
            qoderIndexes[key] = found
        }
        var stamps = [prefix, selection, archive.revision]
        for state in PetAnimationState.allCases {
            guard let path = paths[state], let animated = try archive.resourceStamp(directory + "/" + path.animated), let still = try archive.resourceStamp(directory + "/" + path.still) else { return nil }
            stamps += [animated, still]
        }
        let revision = stamps.joined(separator: "|")
        if let cached = appearances[.qoder], cached.revision == revision { return cached }
        var animations: [PetAnimationState: PetAnimationResource] = [:]
        for state in PetAnimationState.allCases {
            guard let path = paths[state], let animated = try archive.read(directory + "/" + path.animated, limit: PetLimits.image), petIsImage(animated) else { return nil }
            let still = try archive.read(directory + "/" + path.still, limit: PetLimits.image)
            guard still.map(petIsImage) ?? true else { return nil }
            animations[state] = .init(data: animated, stillData: still)
        }
        let result = ProviderPetAppearance(selectionID: selection, displayName: selection == "qoduck" ? "Q 达鸭" : "KleidisDog", revision: revision, sourceDescription: "Qoder CN 内置宠物", animations: animations)
        appearances[.qoder] = result
        return result
    }

    private static func qoderAnimationTable(in text: String) -> [PetAnimationState: QoderAnimationPaths]? {
        let refsPattern = #"([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:[\"\']{2}\s*\+\s*)?new URL\([\"'`]([^\"'`]+\.webp)[\"'`],\s*import\.meta\.url\)\.href"#
        guard let refsRegex = try? NSRegularExpression(pattern: refsPattern) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var references: [String: String] = [:]
        for match in refsRegex.matches(in: text, range: full) {
            guard let varRange = Range(match.range(at: 1), in: text), let pathRange = Range(match.range(at: 2), in: text) else { continue }
            let path = String(text[pathRange]).replacingOccurrences(of: "./", with: "", options: .anchored)
            guard !path.contains("/"), !path.contains("\\"), !path.contains("..") else { continue }
            references[String(text[varRange])] = path
        }
        var table: [PetAnimationState: QoderAnimationPaths] = [:]
        for state in PetAnimationState.allCases {
            let pattern = "(?:^|[,\\{])" + state.rawValue + #":\s*\{animatedSrc:([A-Za-z_$][A-Za-z0-9_$]*),stillSrc:([A-Za-z_$][A-Za-z0-9_$]*)"#
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: full),
                  let aRange = Range(match.range(at: 1), in: text), let sRange = Range(match.range(at: 2), in: text),
                  let animated = references[String(text[aRange])], let still = references[String(text[sRange])] else { return nil }
            table[state] = .init(animated: animated, still: still)
        }
        return table
    }
}
