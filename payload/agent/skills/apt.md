<!-- triggers: apt, apt-get, dpkg, package, install, uninstall, upgrade, ppa -->
# Skill: APT package management on Ubuntu

This skill is loaded when the operator's recent prompts mention APT,
package installs, or related Debian package terms.

Operating rules:

- Prefer the typed `pkg.query` and `pkg.install` tools over `shell.run`
  when answering "is X installed?" or "install X". They are gated by
  the same policy classes but produce cleaner observations.
- For investigation, `pkg.query` wraps `dpkg -s` and `apt-cache policy`.
  Use it before suggesting installs so the operator sees the current
  state.
- For installs, `pkg.install` runs `apt-get install -y` and is
  classified `system_change`; it always waits for operator approval.
- Never call `apt-get update && apt-get upgrade` unattended unless the
  operator explicitly asked for a system upgrade. Upgrades can restart
  services.
- Do not edit `/etc/apt/sources.list` or files under
  `/etc/apt/sources.list.d/` without explicit operator consent; new
  repositories are a security change.
- If a package is missing on the system, report it and ask the
  operator how to proceed. Do not silently fall back to a curl|bash
  install — there is no generic `http.get` tool and that pattern is
  forbidden by the threat model.
