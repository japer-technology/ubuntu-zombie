# bash completion for ubuntu-zombie install.sh
#
# Usage:
#   source scripts/completions/install.bash
#
# Completes the subcommands and flags accepted by scripts/install.sh. This is
# a static completion (it does not execute install.sh), so it is safe to load
# from an interactive shell.

_ubuntu_zombie_install() {
  local cur subcommands flags
  cur="${COMP_WORDS[COMP_CWORD]}"

  subcommands="install verify doctor repair uninstall"
  flags="-h --help -v --version -n --dry-run -y --yes -q --quiet \
         --verbose --debug --no-color --no-colour --strict --json"

  # Has a subcommand already been chosen on the command line?
  local i seen=""
  for (( i = 1; i < COMP_CWORD; i++ )); do
    case "${COMP_WORDS[i]}" in
      install|verify|doctor|repair|uninstall) seen="${COMP_WORDS[i]}"; break ;;
    esac
  done

  if [[ "${cur}" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "${flags}" -- "${cur}")
    return 0
  fi

  if [[ -z "${seen}" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "${subcommands} ${flags}" -- "${cur}")
  else
    # After a subcommand only flags remain meaningful.
    mapfile -t COMPREPLY < <(compgen -W "${flags}" -- "${cur}")
  fi
  return 0
}

# Register for the common invocation names.
complete -F _ubuntu_zombie_install install.sh ./install.sh
