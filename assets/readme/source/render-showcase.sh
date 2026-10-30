#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$project_dir"
./scripts/build-app.sh release
swift build --product LingChongDao
binary_dir="$(swift build --show-bin-path)"
render_dir="$project_dir/dist/readme-capture"
mkdir -p "$render_dir/fixture-home"
export README_FIXTURE_HOME="$render_dir/fixture-home"
# Inject empty pet data, canonical bundle icons and a fake power backend.
# Product views stay unchanged; source settings, real power state and Finder
# custom icons do not enter the capture.
python3 - "$render_dir/PetAppearanceStore.swift" "$render_dir/KeepAwakeController.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/LingChongDao/Pets/PetAppearanceStore.swift').read_text()
needle = 'static let shared = PetAppearanceStore()'
assert source.count(needle) == 1
replacement = '''static let shared = PetAppearanceStore(reader: LocalPetSourceReader(environment:
        PetSourceEnvironment(homeURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["README_FIXTURE_HOME"]!), appDirectories: [])))'''
source = source.replace(needle, replacement, 1)
source = source.replace('NSWorkspace.shared.icon(forFile: applicationURL.path)', 'Self.readmeBundledIcon(applicationURL)')
source = source.replace('NSWorkspace.shared.icon(forFile: url.path)', 'Self.readmeBundledIcon(url)')
helper = '''
    private static func readmeBundledIcon(_ applicationURL: URL) -> NSImage {
        if let bundle = Bundle(url: applicationURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let filename = name.contains(".") ? name : name + ".icns"
            if let image = NSImage(contentsOf: applicationURL.appendingPathComponent("Contents/Resources/" + filename)) {
                return image
            }
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
    }
'''
source = source.rstrip()[:-1] + helper + '}\n'
Path(sys.argv[1]).write_text(source)
source = Path('Sources/LingChongDao/Models/KeepAwakeController.swift').read_text()
needle = 'static let shared = KeepAwakeController()'
assert source.count(needle) == 1
replacement = '''static let shared = KeepAwakeController(
        backend: KeepAwakeBackend(create: { _ in .failure(.creationFailed) }, release: { _ in true }),
        clamshellGuard: ReadmePowerGuard())'''
Path(sys.argv[2]).write_text(source.replace(needle, replacement, 1))
PY
module_links=()
for module in IslandCore IslandConnections IslandPets; do
  if [[ -f "$binary_dir/$module.o" ]]; then
    module_links+=("$binary_dir/$module.o")
  elif [[ -f "$binary_dir/lib$module.a" ]]; then
    module_links+=("$binary_dir/lib$module.a")
  else
    module_links+=("$binary_dir/$module.build/"*.o)
  fi
done
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(find Sources/LingChongDao -name '*.swift' ! -name App.swift ! -name PetAppearanceStore.swift ! -name KeepAwakeController.swift ! -path '*/Connections/*' | sort)
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  "${sources[@]}" "$render_dir/PetAppearanceStore.swift" "$render_dir/KeepAwakeController.swift" assets/readme/source/Capture.swift \
  "${module_links[@]}" -lsqlite3 -framework IOKit -o "$render_dir/capture"
"$render_dir/capture" "$project_dir/assets/readme"
