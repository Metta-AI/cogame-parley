#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, must end up containing index.html).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

output_dir="$1"
if [[ "${output_dir}" != /* ]]; then
  echo "output dir must be absolute: ${output_dir}" >&2
  exit 1
fi

export PATH="$HOME/.nimby/nim/bin:$PATH"

pinned_nim="$(sed -n 's/^FROM nimlang\/nim:\([^ ]*\).*/\1/p' "$repo_dir/Dockerfile.replay-viewer")"
if command -v nim >/dev/null &&
   [[ "$(nim --version | sed -n '1s/^Nim Compiler Version \([^ ]*\).*/\1/p')" == "$pinned_nim" ]]; then
  nim js -d:release --hints:off --skipParentCfg:on --skipProjCfg:on \
    --path:"${repo_dir}/src" --out:"${repo_dir}/replay-viewer/dist/parley_replay.js" \
    "${repo_dir}/replay-viewer/parley_replay.nim"
else
  image_tag="parley-replay-viewer-build:$$"
  docker build --load --platform linux/amd64 \
    --file "${repo_dir}/Dockerfile.replay-viewer" \
    --tag "${image_tag}" "${repo_dir}"
  container_id="$(docker create "${image_tag}")"
  mkdir -p "${repo_dir}/replay-viewer/dist"
  docker cp "${container_id}:/workspace/parley/replay-viewer/dist/parley_replay.js" \
    "${repo_dir}/replay-viewer/dist/parley_replay.js"
  docker rm "${container_id}" >/dev/null
  docker image rm "${image_tag}" >/dev/null
fi

dist="${repo_dir}/replay-viewer/dist"
test -s "${dist}/parley_replay.js"

rm -rf "${output_dir}"
mkdir -p "${output_dir}/assets"
cp "${dist}/parley_replay.js" "${output_dir}/"
cp "${repo_dir}/client/replay.html" "${output_dir}/index.html"
cp "${repo_dir}/client/replay.js" \
  "${repo_dir}/client/renderer.js" \
  "${repo_dir}/client/reasoning.js" \
  "${repo_dir}/client/chrome.css" \
  "${output_dir}/"
for asset in soldier_red_front.png soldier_blue_front.png \
  soldier_green_front.png soldier_yellow_front.png \
  soldier_red_front_gun.png soldier_blue_front_gun.png \
  soldier_green_front_gun.png soldier_yellow_front_gun.png \
  heart_red.png arena_floor.png paintgun.png font.ttf; do
  cp "${repo_dir}/data/${asset}" "${output_dir}/assets/"
done

test -f "${output_dir}/index.html"
grep -q 'data-replay' "${output_dir}/replay.js"
echo "parley replay viewer bundle: ${output_dir}"
