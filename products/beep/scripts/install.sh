#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
needs_root=1
skip_next=0

for argument in "$@"; do
  if (( skip_next )); then
    skip_next=0
    continue
  fi
  case "${argument}" in
    --) break ;;
    --dry-run|-h|--help) needs_root=0 ;;
    --request-file|--correlation-id|--plan-digest|--confirmation)
      skip_next=1
      ;;
  esac
done

if (( EUID != 0 && needs_root )); then
  prohibited_environment=(
    BEEP_ADMIN_PASSWORD
    BEEP_PROVIDER_CREDENTIAL
    BEEP_API_KEY
  )
  for name in "${prohibited_environment[@]}"; do
    if [[ -v ${name} ]]; then
      echo "Raw Beep secrets are prohibited; use a protected file." >&2
      exit 65
    fi
  done
  environment_names=(
    BEEP_NONINTERACTIVE
    BEEP_USER
    BEEP_CHAT_PORT
    BEEP_ADMIN_PASSWORD_FILE
    BEEP_PROVIDER
    BEEP_PROVIDER_CREDENTIAL_FILE
    BEEP_MODEL
    BEEP_MODEL_BASE_URL
    BEEP_TTL_DAYS
    BEEP_BACKUP_DESTINATION
    BEEP_ARTIFACT_SHA256
    BEEP_DISPOSABLE_VM_TEST
  )
  while IFS= read -r name; do
    if [[ ${name} == BEEP_* \
      && " ${environment_names[*]} " != *" ${name} "* ]]; then
      echo "Unknown Beep environment variable: ${name}" >&2
      exit 65
    fi
  done < <(compgen -e)
  sudo_environment=(
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "HOME=/root"
    "LANG=C.UTF-8"
    "LC_ALL=C.UTF-8"
  )
  for name in "${environment_names[@]}"; do
    if [[ -v ${name} ]]; then
      sudo_environment+=("${name}=${!name}")
    fi
  done
  network_environment=(
    HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY
    http_proxy https_proxy no_proxy all_proxy
    SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
  )
  for name in "${network_environment[@]}"; do
    if [[ -v ${name} ]]; then
      sudo_environment+=("${name}=${!name}")
    fi
  done
  [[ -x /usr/bin/sudo && ! -L /usr/bin/sudo ]] || {
    echo "Beep installation requires root; rerun this installer as root." >&2
    exit 73
  }
  exec /usr/bin/sudo -- /usr/bin/env -i "${sudo_environment[@]}" \
    "${script_dir}/manage.sh" install "$@"
fi

exec "${script_dir}/manage.sh" install "$@"
