#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script_name="${BASH_SOURCE[0]##*/}"

if [[ "${script_name}" == "beep-manage" ]]; then
  source_root="/opt/beep/product"
else
  source_root="$(cd -- "${script_dir}/.." && pwd -P)"
fi

if [[ ! -f "${source_root}/payload/agent/beep/management.py" ]]; then
  echo "Beep management code is unavailable at ${source_root}." >&2
  exit 66
fi

if ! unsafe_link="$(/usr/bin/find "${source_root}" -type l -print -quit)"; then
  echo "Beep management code cannot be inspected at ${source_root}." >&2
  exit 66
fi
if [[ -n "${unsafe_link}" ]]; then
  echo "Beep source contains a symlink: ${unsafe_link}" >&2
  exit 78
fi
if ! unsafe_path="$(
  /usr/bin/find "${source_root}" ! -type d ! -type f -print -quit
)"; then
  echo "Beep management code cannot be inspected at ${source_root}." >&2
  exit 66
fi
if [[ -n "${unsafe_path}" ]]; then
  echo "Beep source contains an unsupported path: ${unsafe_path}" >&2
  exit 78
fi

if [[ "${script_name}" == "beep-manage" ]]; then
  while IFS= read -r -d '' path; do
    if ! metadata="$(/usr/bin/stat --format='%u %a' -- "${path}")"; then
      echo "Installed Beep source cannot be inspected: ${path}" >&2
      exit 73
    fi
    owner="${metadata%% *}"
    permissions="${metadata#* }"
    if [[ "${owner}" != "0" ]] \
      || (( (8#${permissions} & 8#022) != 0 )); then
      echo "Installed Beep source is unsafe: ${path}" >&2
      exit 73
    fi
  done < <(
    /usr/bin/find /opt/beep /opt/beep/product -maxdepth 0 -print0
    /usr/bin/find /opt/beep/product -mindepth 1 -print0
  )
fi

export BEEP_SOURCE_ROOT="${source_root}"
cd -- "${source_root}"
exec /usr/bin/python3 -I -c '
import runpy
import sys

module_root = sys.argv.pop(1)
sys.path.insert(0, module_root)
runpy.run_module("beep.management", run_name="__main__", alter_sys=True)
' "${source_root}/payload/agent" "$@"
