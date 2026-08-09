# Troubleshooting

## Start with doctor and beep-health

```bash
sudo ./scripts/install.sh doctor
/opt/beep/bin/beep-health
```

`doctor` explains installer/runtime drift. `beep-health` gives a local
summary of the chat service, provider token state, disk space, audit log,
secrets file permissions, agent venv, and pi binaries.

## Chat does not load

Check the service:

```bash
sudo systemctl status beep-chat.service
sudo journalctl -u beep-chat.service -n 100 --no-pager
```

The chat service intentionally binds to `127.0.0.1` only. Open it from
the Beep machine at `http://127.0.0.1:7878/`, or use your own
remote-access mechanism outside Beep.

## Provider errors

Edit provider secrets and restart the chat service:

```bash
sudo /opt/beep/bin/beep-secrets-edit
sudo systemctl restart beep-chat.service
```

Then inspect recent audit/provider records:

```bash
/opt/beep/bin/beep-audit -t provider_error -t tool_call
```

## Installer drift

Re-apply known-safe files and permissions:

```bash
sudo ./scripts/install.sh repair
```

This re-asserts ownership/modes, re-renders pi-mono configuration,
redeploys built-in skills, and restarts the chat service.

## Collect diagnostics

```bash
/opt/beep/bin/beep-diagnostics
```

The bundle redacts provider keys, token-shaped strings, private keys,
password assignments, and the secrets-file path before writing a tarball
under `/tmp`.
