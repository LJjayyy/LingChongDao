#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --product LingChongDao
binary_dir="$(swift build --show-bin-path)"
if [[ -f "$binary_dir/IslandPets.o" ]]; then
  pet_link=("$binary_dir/IslandPets.o" "$binary_dir/IslandCore.o")
elif [[ -f "$binary_dir/libIslandPets.a" ]]; then
  pet_link=("$binary_dir/libIslandPets.a" "$binary_dir/libIslandCore.a")
else
  pet_link=("$binary_dir"/IslandPets.build/*.o "$binary_dir"/IslandCore.build/*.o)
fi
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  Sources/LingChongDao/Pets/PetAnimationDecoder.swift Sources/LingChongDao/Pets/PetAppearanceStore.swift \
  Tests/PetRenderVerification/Verification.swift \
  "${pet_link[@]}" -lsqlite3 -o "$binary_dir/lingchongdao-verify-pet-renderer"
"$binary_dir/lingchongdao-verify-pet-renderer" "$@"
