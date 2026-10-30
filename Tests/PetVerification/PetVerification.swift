import Foundation
import SQLite3
import IslandCore
import IslandPets

struct VerificationFailure: Error { let message: String }

@main struct PetVerification {
    static var checks = 0
    // Synthetic format signatures only: source-provider artwork never enters fixtures.
    static let image = Data([82,73,70,70,4,0,0,0,87,69,66,80])
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(message: message) }; checks += 1
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func writeJSON(_ object: [String: Any], to url: URL) throws { try write(JSONSerialization.data(withJSONObject: object, options: .sortedKeys), to: url) }
    static func setQoder(_ selection: String, environment: PetSourceEnvironment) throws {
        let url = environment.qoderDataURL.appendingPathComponent("main.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS app_settings(setting_key TEXT PRIMARY KEY,value_json TEXT,updated_at TEXT)", nil, nil, nil) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture create") }
        let value = String(data: try JSONSerialization.data(withJSONObject: selection, options: .fragmentsAllowed), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "INSERT OR REPLACE INTO app_settings VALUES('desktopPet.activePetId','\(value)','\(UUID().uuidString)')", nil, nil, nil) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture selection") }
    }
    static func setQoderEnabled(_ value: String?, environment: PetSourceEnvironment) throws {
        let url = environment.qoderDataURL.appendingPathComponent("main.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS app_settings(setting_key TEXT PRIMARY KEY,value_json TEXT,updated_at TEXT)", nil, nil, nil) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture create") }
        if let value {
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            guard sqlite3_exec(db, "INSERT OR REPLACE INTO app_settings VALUES('desktopPet.enabled','\(escaped)','fixture')", nil, nil, nil) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture enabled") }
        } else {
            guard sqlite3_exec(db, "DELETE FROM app_settings WHERE setting_key='desktopPet.enabled'", nil, nil, nil) == SQLITE_OK else { throw VerificationFailure(message: "SQLite fixture delete enabled") }
        }
    }
    static func setCodex(_ selection: String, environment: PetSourceEnvironment) throws {
        try write(Data("[other]\nselected-avatar-id = \"ignored\"\n[desktop]   # fixture section\nselected-avatar-id = \"\(selection)\" # fixture\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
    }
    static func custom(_ slug: String, environment: PetSourceEnvironment, version: Int = 2, imagePath: String = "spritesheet.webp") throws {
        let root = environment.codexHomeURL.appendingPathComponent("pets/" + slug, isDirectory: true)
        try writeJSON(["displayName": "Fixture " + slug, "spriteVersionNumber": version, "spritesheetPath": imagePath], to: root.appendingPathComponent("pet.json"))
        try write(image, to: root.appendingPathComponent("spritesheet.webp"))
    }
    static func asar(_ resources: [String: Data], at url: URL, badOffset: Bool = false, unpacked: Set<String> = []) throws {
        var payload = Data()
        var root: [String: Any] = ["files": [String: Any]()]
        func insert(_ path: ArraySlice<String>, node: inout [String: Any], entry: [String: Any]) {
            guard let key = path.first else { return }
            var files = node["files"] as? [String: Any] ?? [:]
            if path.count == 1 { files[key] = entry }
            else { var child = files[key] as? [String: Any] ?? ["files": [String: Any]()]; insert(path.dropFirst(), node: &child, entry: entry); files[key] = child }
            node["files"] = files
        }
        for key in resources.keys.sorted() {
            let data = resources[key]!
            let entry: [String: Any]
            if unpacked.contains(key) { entry = ["size": data.count, "unpacked": true]; try write(data, to: URL(fileURLWithPath: url.path + ".unpacked").appendingPathComponent(key)) }
            else { entry = ["size": data.count, "offset": badOffset ? "999999999" : String(payload.count)]; payload.append(data) }
            insert(key.split(separator: "/").map(String.init)[...], node: &root, entry: entry)
        }
        let json = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        let padding = (4 - json.count % 4) % 4
        let headerSize = 8 + json.count + padding
        var data = Data()
        for integer in [4, headerSize, headerSize - 4, json.count] { var value = UInt32(integer).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(json); data.append(Data(repeating: 0, count: padding)); data.append(payload)
        try write(data, to: url)
    }

    static func main() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lingchongdao-pet-fixtures-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let apps = home.appendingPathComponent("Applications", isDirectory: true)
            let environment = PetSourceEnvironment(homeURL: home, appDirectories: [apps])
            let reader = LocalPetSourceReader(environment: environment)
            try check(try await reader.isPetEnabled(.generic) == false, "generic is never enabled")
            try check(try await reader.isPetEnabled(.qoder) == false, "missing Qoder database is disabled")
            try setQoder("petdex:chosen", environment: environment)
            try setQoderEnabled("false", environment: environment)
            try check(try await reader.isPetEnabled(.qoder) == false, "active Qoder selection does not imply enabled")
            try setQoderEnabled("true", environment: environment)
            try check(try await reader.isPetEnabled(.qoder), "Qoder JSON boolean true")
            try setQoderEnabled("\"true\"", environment: environment)
            try check(try await reader.isPetEnabled(.qoder) == false, "Qoder string true is not boolean")
            try setQoderEnabled(nil, environment: environment)
            try check(try await reader.isPetEnabled(.qoder) == false, "missing Qoder enabled key")
            try check(try await reader.isPetEnabled(.codex) == false, "missing Codex config is disabled")
            try setCodex("codex", environment: environment)
            try check(try await reader.isPetEnabled(.codex), "Codex selected avatar uses default visible=true")
            try write(Data("[other]\n\"avatar-overlay-pet-visible\" = true\n\"selected-avatar-id\" = \"ignored\"\n[\"desktop\"] # quoted section\n\"avatar-overlay-pet-visible\" = false # explicit off\n\"selected-avatar-id\" = \"chosen\" # chosen\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex) == false, "Codex explicit false overrides selection; quoted keys/comments supported")
            try write(Data("[other]\navatar-overlay-pet-visible = false\nselected-avatar-id = \"ignored\"\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex) == false, "Codex ignores wrong section")
            try write(Data("[desktop]\navatar-overlay-pet-visible = \"true\"\nselected-avatar-id = \"chosen\"\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex) == false, "Codex string true is invalid even when an avatar is selected")
            try write(Data("[desktop]\navatar-overlay-pet-visible = true\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex), "Codex reflects changed setting without restart")
            try write(Data("[desktop]\nselected-avatar-id = \"chosen\"\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex), "Codex selected avatar with default visibility")
            try write(Data("[desktop]\nselected-avatar-id = \"\"\n".utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
            try check(try await reader.isPetEnabled(.codex) == false, "Codex no visibility and no selection stays disabled")
            try check(try await reader.read(.generic) == nil, "generic has no fake pet")
            try check(try await reader.read(.codex) == nil, "missing app returns nil")
            try custom("first", environment: environment)
            try setCodex("custom:first", environment: environment)
            guard let first = try await reader.read(.codex) else { throw VerificationFailure(message: "custom Codex missing") }
            try check(first.selectionID == "custom:first" && first.displayName == "Fixture first", "selected custom manifest")
            try check(first.animations.count == 5, "five states")
            try check(first.animations[.idle]?.spriteLayout?.rows == 11, "v2 rows")
            try check(first.animations[.running]?.spriteLayout?.row == 7 && first.animations[.running]?.spriteLayout?.frameDurations.count == 6, "running contract")
            try check(first.animations[.failed]?.spriteLayout?.row == 5 && first.animations[.failed]?.spriteLayout?.frameDurations.count == 8, "failed contract")
            try check(first.animations[.waiting]?.spriteLayout?.row == 6 && first.animations[.review]?.spriteLayout?.row == 8, "waiting/review contract")
            try check(abs((first.animations[.idle]?.spriteLayout?.frameDurations.first ?? 0) - 1.68) < 0.000001, "idle slowed as source")
            let same = try await reader.read(.codex)
            try check(same?.revision == first.revision, "unchanged revision stable")
            try custom("second", environment: environment, version: 1)
            try setCodex("custom:second", environment: environment)
            let second = try await reader.read(.codex)
            try check(second?.selectionID == "custom:second" && second?.revision != first.revision, "selection follows changes")
            try check(second?.animations[.idle]?.spriteLayout?.rows == 9, "v1 rows")
            try writeJSON(["displayName": "Changed", "spritesheetPath": "spritesheet.webp"], to: environment.codexHomeURL.appendingPathComponent("pets/second/pet.json"))
            let changed = try await reader.read(.codex)
            try check(changed?.displayName == "Changed" && changed?.revision != second?.revision, "manifest changes refresh")
            try writeJSON(["electron-persisted-atom-state": ["migrated-cloud-pet-ids-v1": ["opaque-fixture-scope": ["custom:first": "pet_fixture"]]]], to: environment.codexHomeURL.appendingPathComponent(".codex-global-state.json"))
            try setCodex("pet_fixture", environment: environment)
            let cloud = try await reader.read(.codex)
            try check(cloud?.selectionID == "pet_fixture" && cloud?.displayName == "Fixture first", "cloud exact alias")
            try check(cloud?.sourceDescription.contains("本地素材") == true, "cloud source accurately labelled")
            try writeJSON(["unrelated-ui-setting": "changed", "electron-persisted-atom-state": ["migrated-cloud-pet-ids-v1": ["opaque-fixture-scope": ["custom:first": "pet_fixture"]]]], to: environment.codexHomeURL.appendingPathComponent(".codex-global-state.json"))
            let unchangedCloud = try await reader.read(.codex)
            try check(unchangedCloud?.revision == cloud?.revision, "unrelated global state does not reload artwork")
            try setCodex("pet_missing", environment: environment)
            try check(try await reader.read(.codex) == nil, "cloud without alias returns nil")
            try setCodex("custom:../outside", environment: environment)
            do { _ = try await reader.read(.codex); throw VerificationFailure(message: "unsafe identity accepted") } catch is PetSourceError { checks += 1 }
            try custom("unsafe", environment: environment, imagePath: "../first/spritesheet.webp")
            try setCodex("custom:unsafe", environment: environment)
            do { _ = try await reader.read(.codex); throw VerificationFailure(message: "unsafe manifest accepted") } catch is PetSourceError { checks += 1 }
            try custom("symlink", environment: environment)
            let link = environment.codexHomeURL.appendingPathComponent("pets/symlink/spritesheet.webp")
            try FileManager.default.removeItem(at: link)
            let outside = home.appendingPathComponent("outside.webp")
            try write(image, to: outside)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try setCodex("custom:symlink", environment: environment)
            do { _ = try await reader.read(.codex); throw VerificationFailure(message: "symlink escape accepted") } catch is PetSourceError { checks += 1 }
            let codexASAR = apps.appendingPathComponent("ChatGPT.app/Contents/Resources/app.asar")
            try asar(["webview/assets/codex-spritesheet-v2-fixture.webp": image, "webview/assets/codex-other-spritesheet-v2-fixture.webp": Data()], at: codexASAR)
            try setCodex("codex", environment: environment)
            let builtin = try await reader.read(.codex)
            try check(builtin?.selectionID == "codex" && builtin?.animations[.idle]?.data == image, "builtin exact filename via ASAR")
            try setCodex("unsupported", environment: environment)
            try check(try await reader.read(.codex) == nil, "unsupported builtin does not use another pet")
            try asar(["webview/assets/codex-spritesheet-v1-unpacked.webp": image], at: codexASAR, unpacked: ["webview/assets/codex-spritesheet-v1-unpacked.webp"])
            try setCodex("codex", environment: environment)
            try check(try await reader.read(.codex)?.animations[.idle]?.spriteLayout?.rows == 9, "ASAR unpacked resource")
            try asar(["webview/assets/codex-spritesheet-v1-bad.webp": image], at: codexASAR, badOffset: true)
            do { _ = try await reader.read(.codex); throw VerificationFailure(message: "ASAR offset accepted") } catch is PetSourceError { checks += 1 }
            try setQoder("petdex:fixture", environment: environment)
            let cache = environment.qoderDataURL.appendingPathComponent("desktop-pet-assets/petdex-appearance-v1-fixture.json")
            let dataURL = "data:image/webp;base64," + image.base64EncodedString()
            var states: [String: Any] = [:]
            for state in PetAnimationState.allCases { states[state.rawValue] = ["animatedSrc": dataURL, "stillSrc": dataURL] }
            try writeJSON(["petId": "petdex:fixture", "displayName": "Qoder Fixture", "animationSet": states], to: cache)
            try write(Data("{broken old cache".utf8), to: environment.qoderDataURL.appendingPathComponent("desktop-pet-assets/petdex-appearance-v1-broken.json"))
            let qoder = try await reader.read(.qoder)
            try check(qoder?.selectionID == "petdex:fixture" && qoder?.displayName == "Qoder Fixture", "Qoder SQLite exact selected cache")
            try check(qoder?.animations[.running]?.spriteLayout == nil && qoder?.animations[.running]?.stillData == image, "Qoder compiled animated WebP")
            try check(try await reader.read(.qoder)?.revision == qoder?.revision, "Qoder cache revision stable")
            try setQoder("unrecognized", environment: environment)
            try check(try await reader.read(.qoder) == nil, "Qoder unknown selection fallback")
            // Upgraded Vite filenames are resolved from a bounded, exact animation table.
            let qoderASAR = apps.appendingPathComponent("Qoder CN.app/Contents/Resources/app.asar")
            var entries: [String: Data] = [:]
            var js = ""
            var table: [String] = []
            for (index, state) in PetAnimationState.allCases.enumerated() {
                let a = state.rawValue + "-fixture.webp", s = "still-fixture-" + state.rawValue + ".webp"
                entries["out/renderer/assets/" + a] = image; entries["out/renderer/assets/" + s] = image
                js += "const a\(index)=\"\"+new URL(\"\(a)\",import.meta.url).href,s\(index)=new URL(\"\(s)\",import.meta.url).href;"
                table.append(state.rawValue + ":{animatedSrc:a\(index),stillSrc:s\(index)}")
            }
            js += "const defaultDesktopPetAnimationSet={" + table.joined(separator: ",") + "};"
            entries["out/renderer/assets/new-hash.js"] = Data(js.utf8)
            try asar(entries, at: qoderASAR)
            try setQoder("qoduck", environment: environment)
            let duck = try await reader.read(.qoder)
            try check(duck?.displayName == "Q 达鸭" && duck?.animations.count == 5, "Qoder upgraded module table")
            try setQoder("kleidisDog", environment: environment)
            try check(try await reader.read(.qoder) == nil, "Qoder never confuses duck with dog")
            print("PASS \(checks) pet source checks; synthetic fixtures only")
        } catch {
            fputs("Pet verification failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
