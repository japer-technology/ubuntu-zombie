#compdef install.sh
# zsh completion for ubuntu-zombie install.sh
#
# Usage:
#   Put scripts/completions/ on your $fpath, then:
#     autoload -U compinit && compinit
#
# Static completion: it does not execute install.sh.

_ubuntu_zombie_install() {
  local -a subcommands flags
  subcommands=(
    'install:Install and harden the agent host'
    'verify:Check that the install is healthy'
    'doctor:Diagnose host/config problems'
    'repair:Re-apply idempotent fixes'
    'uninstall:Remove the agent host configuration'
  )
  flags=(
    '(-h --help)'{-h,--help}'[Show help and exit]'
    '(-v --version)'{-v,--version}'[Show version and exit]'
    '(-n --dry-run)'{-n,--dry-run}'[Preview actions without changing the host]'
    '(-y --yes)'{-y,--yes}'[Skip the YES confirmation gate]'
    '(-q --quiet)'{-q,--quiet}'[Only print warnings and errors]'
    '--verbose[Trace execution to the transcript]'
    '--debug[Trace execution to the transcript]'
    '--no-color[Disable coloured output]'
    '--no-colour[Disable coloured output]'
    '--strict[Treat preflight warnings as errors]'
    '--json[Machine-readable output for verify/doctor]'
  )

  _arguments -C \
    "${flags[@]}" \
    '1: :->subcmd' \
    '*:: :->args'

  case "${state}" in
    subcmd) _describe -t commands 'subcommand' subcommands ;;
    args)   _arguments "${flags[@]}" ;;
  esac
}

_ubuntu_zombie_install "$@"
