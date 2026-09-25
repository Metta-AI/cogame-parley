#!/usr/bin/env bash
set -euo pipefail

nim_subcommand="$1"
shift
nim_paths=()
for package in "$HOME"/.nimby/pkgs/*; do
  if [[ -d "$package/src" ]]; then
    nim_paths+=("--path:$package/src")
  else
    nim_paths+=("--path:$package")
  fi
done
exec nim "$nim_subcommand" "${nim_paths[@]}" --path:src "$@"
