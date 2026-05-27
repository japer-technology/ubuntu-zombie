<!-- triggers: docker, container, compose, dockerd, image, podman -->
# Skill: Docker on Ubuntu

This skill is loaded when the operator mentions Docker, containers,
images, or Compose.

Operating rules:

- Use `shell.run` with `docker ps`, `docker images`, `docker inspect`,
  and `docker logs --tail` for diagnostics; they are `read_only`
  under the default policy and run automatically.
- `docker run`, `docker build`, `docker pull`, `docker rm -f`,
  `docker volume rm`, and `docker system prune` are mutating. Prefer
  the most surgical command available and let the policy gate ask the
  operator to approve.
- Do not bind-mount the host's root filesystem (`-v /:/host`) or run
  containers with `--privileged` unless the operator explicitly asked
  and acknowledged the blast radius.
- Never include the operator's secrets file path
  (`/opt/ai-zombie/secrets/env`) as a bind mount or build argument.
  Secrets must reach a container only through the operator's chosen
  channel (e.g. `--env-file` on a separate, intentionally exported
  file).
- For Compose, prefer `docker compose ps` / `docker compose logs`
  before suggesting `up`/`down`. Compose `down -v` deletes volumes
  and is destructive; warn explicitly when suggesting it.
