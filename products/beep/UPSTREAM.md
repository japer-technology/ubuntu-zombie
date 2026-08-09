# Pinned source lessons and provenance

Beep's initial runtime was copied and independently renamed from the audited
Ubuntu Zombie lesson set present in repository commit
`f148dd6f4f26e9a410a1880a08437578e17bd053`. The copied lesson areas were:

- chat authentication, session handling, provider adapters, conversation
  history, reactivation, policy, audit, runner, and closed tool registry;
- the pi-mono bridge lock, bridge, model metadata, prompt templates, skills,
  operator helpers, systemd assets, log rotation, and default policy; and
- the provider and systems-administration behaviour required for product
  parity.

Before first use, those lessons were placed below `products/beep/` and changed
to Beep-owned module names, paths, credentials, cookie, port, lifecycle state,
audit, service units, family catalogue, inventory, receipts, and commands.
Beep's independent lifecycle and family managers were then implemented below
this product root.

The runtime pins Node `22.23.2` and verifies its upstream archive digest.
`payload/agent/bridge-dependencies.lock` pins each npm bridge package version,
URL, integrity digest, licence, and source. Release artifacts record the exact
Beep commit, test result, SPDX SBOM, checksums, GitHub attestation, and cosign
signature material.

Beep does not import or install files from `/opt/ai-zombie`,
`/etc/ubuntu-zombie`, `/var/lib/ubuntu-zombie`, or `/var/log/ubuntu-zombie`.
Future Ubuntu Zombie changes are not inherited automatically; they require a
reviewed Beep change and a new independent Beep version.
