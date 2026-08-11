# Backup, update, and rollback

Review and verify every Beep release; never point the installed wrapper at an
unverified checkout.

## Backup

Choose an absolute destination outside all product roots:

```bash
sudo env BEEP_BACKUP_DESTINATION=/srv/backup/beep \
  beep-manage backup --yes --json
```

Backup stops useful Beep work, rejects links and unsupported files in owned
trees, writes a mode-`0600` archive with a product manifest, verifies the
archive, and resumes only if Beep was neither suspended nor dead.

## Update

Run the lifecycle command from the newly extracted, independently verified
Beep release:

```bash
sudo /path/to/verified/products/beep/scripts/manage.sh \
  update --dry-run --json
sudo /path/to/verified/products/beep/scripts/manage.sh \
  update --yes --json
```

Supply protected configuration inputs only when intentionally rotating them.
The manager validates the new descriptor and source, stops services, creates a
recovery snapshot, preserves data and tombstones, converges root-owned runtime
files atomically, validates policy, credentials, dependencies, units, family
assets, and service state, then updates the ownership marker and receipt.
The approved source revision and protected-input fingerprints are recomputed
under the lifecycle lock. Deployment then reads only from a private trusted
snapshot of that exact revision, so a checkout change after plan approval is a
`PLAN_CHANGED` failure rather than mixed installed code.

If convergence or the health gate fails, Beep restores the pre-operation
snapshot and previous service state automatically. Package installations or
an external action already completed on the host may require separate
operator recovery and are not falsely claimed as reversed.

## Rollback

Use explicit rollback when a completed update must be undone:

```bash
sudo beep-manage rollback --dry-run --json
sudo beep-manage rollback --yes --json
```

Rollback accepts only the latest Beep-owned snapshot whose product,
correlation, instance, version, host-file allow-list, ownership map, and tree
digests validate. It never restores a sibling path. It preserves the recovery
root, restores compatible configuration and state, then verifies the restored
manager and service boundary. The snapshot records absent roots and exact
pre-operation service enablement and activity. Rollback stages replacements on
each destination filesystem and reverses already-applied swaps if a later
application or ownership step fails; a degraded restore always leaves
privileged services stopped.

Keep external backups before schema migrations or high-impact host work. Test
backup restoration and rollback on a disposable VM for each release.
