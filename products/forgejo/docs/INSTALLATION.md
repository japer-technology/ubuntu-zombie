# Installation

Use a supported Ubuntu Desktop 22.04 or 24.04 LTS host:

```bash
cd products/forgejo
./scripts/manage.sh install --dry-run
sudo ./scripts/manage.sh install --yes
sudo /usr/local/sbin/forgejo-manage verify
```

The product installs only dependencies already used by the former component:
Forgejo, Git LFS, PostgreSQL, Caddy, Avahi, certificate tools, and mDNS NSS
support.

An existing component installation is adopted only when its root-owned
manifest, account, loopback configuration, complete recovery secrets, unit,
and unmanaged-drop-in boundary validate. Adoption requires:

```bash
sudo ./scripts/manage.sh install --yes \
  --confirmation "ADOPT FORGEJO"
```

Ambiguous partial state is rejected before mutation. The Ubuntu Zombie
`install forgejo` compatibility command supplies this confirmation only to
the exact legacy validator.

After installation, import `/etc/forgejo/caddy-local-ca.crt` into any LAN
client that does not already trust the host's Caddy CA.
