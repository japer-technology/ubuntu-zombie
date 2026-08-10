from __future__ import annotations

import json
import os
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

from forgejo.management import (
    ADOPT_CONFIRMATION,
    Configuration,
    Invocation,
    ManagementError,
    Manager,
    Paths,
)


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class ManagementTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.paths = Paths(
            install_root=root / "opt/forgejo",
            configuration_root=root / "etc/forgejo",
            state_root=root / "var/lib/forgejo",
            log_root=root / "var/log/forgejo",
            cache_root=root / "var/cache/forgejo",
            unit=root / "etc/systemd/system/forgejo.service",
            logrotate=root / "etc/logrotate.d/forgejo-product",
            entrypoint=root / "usr/local/sbin/forgejo-manage",
            binary=root / "usr/local/bin/forgejo",
            lock=root / "run/lock/forgejo.lock",
            backup_root=root / "var/backups/forgejo",
            caddyfile=root / "etc/caddy/Caddyfile",
            legacy_caddy=root / "etc/caddy/conf.d/forgejo.caddy",
            avahi_service=root / "etc/avahi/services/forgejo.service",
            caddy_ca=root / "var/lib/caddy/root.crt",
            trusted_ca=root
            / "usr/local/share/ca-certificates/forgejo-local-ca.crt",
            legacy_manifest=root / "var/lib/ubuntu-zombie/components/forgejo",
        )
        self.manager = Manager(SOURCE_ROOT)
        self.manager.paths = self.paths

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def invocation(
        operation: str = "install",
        *,
        inputs: dict[str, object] | None = None,
        dry_run: bool = False,
        confirmation: str | None = None,
    ) -> Invocation:
        return Invocation(
            operation=operation,
            correlation_id=str(uuid.uuid4()),
            actor="operator",
            inputs=inputs or {},
            confirmation=confirmation,
            retain_state=True if operation == "uninstall" else None,
            dry_run=dry_run,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )

    def test_descriptor_preserves_existing_namespaces(self) -> None:
        descriptor = self.manager.descriptor
        self.assertEqual(descriptor["install_root"], "/opt/forgejo")
        self.assertEqual(descriptor["state_root"], "/var/lib/forgejo")
        self.assertEqual(descriptor["accounts"][0], {"name": "git", "kind": "user"})
        self.assertEqual(
            descriptor["ports"][0],
            {"address": "127.0.0.1", "port": 3000, "protocol": "tcp"},
        )

    def test_default_configuration_is_loopback_and_https(self) -> None:
        with mock.patch.object(self.manager, "_host", return_value="forge.local"):
            configuration = self.manager.configuration(self.invocation())
        self.assertEqual(configuration.host, "forge.local")
        self.assertEqual(configuration.root_url, "https://forge.local/")
        self.assertEqual(configuration.database_name, "forgejo")
        self.assertEqual(configuration.upstream_version, "latest")
        self.assertNotIn("password", json.dumps(configuration.public_object()))

    def test_existing_public_host_is_preserved(self) -> None:
        self.paths.configuration_root.mkdir(parents=True)
        self.paths.app_ini.write_text(
            """[database]
NAME = forgejo
USER = forgejo
[server]
DOMAIN = existing.local
ROOT_URL = https://existing.local/
""",
            encoding="utf-8",
        )
        configuration = self.manager.configuration(self.invocation())
        self.assertEqual(configuration.host, "existing.local")

    def test_fixed_port_cannot_be_overridden(self) -> None:
        with mock.patch.dict(os.environ, {"FORGEJO_HTTP_PORT": "3001"}):
            with self.assertRaises(ManagementError) as raised:
                self.manager.configuration(self.invocation())
        self.assertEqual(raised.exception.code, "INVALID_CONFIGURATION")

    def test_dry_run_is_non_mutating_and_stable(self) -> None:
        invocation = self.invocation(dry_run=True)
        with mock.patch.object(self.manager, "_host", return_value="forge.local"):
            result, exit_code = self.manager.run(invocation)
            repeated, repeated_exit = self.manager.run(invocation)
        self.assertEqual((exit_code, repeated_exit), (0, 0))
        self.assertEqual(result.plan_digest, repeated.plan_digest)
        self.assertFalse(result.changed)
        self.assertFalse(self.paths.lock.exists())
        self.assertFalse(self.paths.install_root.exists())

    def test_caddy_render_replaces_only_managed_legacy_block(self) -> None:
        self.paths.caddyfile.parent.mkdir(parents=True)
        self.paths.caddyfile.write_text(
            """unrelated.local {
  respond "ok"
}
# BEGIN install.sh Forgejo
https://old.local {
  tls internal
  reverse_proxy 127.0.0.1:3000
}
# END install.sh Forgejo
""",
            encoding="utf-8",
        )
        rendered = self.manager._render_caddyfile("new.local").decode()
        self.assertIn('unrelated.local {\n  respond "ok"\n}', rendered)
        self.assertIn("https://new.local {", rendered)
        self.assertNotIn("old.local", rendered)
        self.assertEqual(rendered.count("# BEGIN forgejo-manage Forgejo"), 1)

    def test_incomplete_caddy_ownership_is_rejected(self) -> None:
        with self.assertRaises(ManagementError) as raised:
            self.manager._without_managed_caddy_blocks(
                "# BEGIN install.sh Forgejo\nhttps://forge.local {\n"
            )
        self.assertEqual(raised.exception.code, "CADDY_OWNERSHIP_AMBIGUOUS")

    def test_runner_boundary_requires_resolution_ca_and_restrictions(self) -> None:
        self.paths.configuration_root.mkdir(parents=True)
        self.paths.app_ini.write_text(
            """[database]
NAME = forgejo
USER = forgejo
[server]
DOMAIN = forge.local
ROOT_URL = https://forge.local/
""",
            encoding="utf-8",
        )
        runner = Path(self.temporary.name) / "runner.yaml"
        runner.write_text(
            """runner:
  envs:
    SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt
    NODE_EXTRA_CA_CERTS: /etc/ssl/certs/ca-certificates.crt
container:
  network: host
  privileged: false
  options: "--add-host forge.local:127.0.0.1 --volume /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
  valid_volumes: []
  docker_host: "-"
""",
            encoding="utf-8",
        )
        with mock.patch("forgejo.management.Path") as path_type:
            path_type.return_value = runner
            self.assertTrue(self.manager._runner_same_host_config_valid())
        runner.write_text("container:\n  network: host\n", encoding="utf-8")
        with mock.patch("forgejo.management.Path") as path_type:
            path_type.return_value = runner
            self.assertFalse(self.manager._runner_same_host_config_valid())

    def test_adoption_requires_exact_confirmation(self) -> None:
        with (
            mock.patch.object(
                self.manager, "_legacy_installation_valid", return_value=True
            ),
            mock.patch.object(self.manager, "load_marker", return_value=None),
            mock.patch.object(self.manager, "_transaction_instance", return_value=None),
        ):
            with self.assertRaises(ManagementError) as raised:
                self.manager._collision_preflight(self.invocation())
            self.assertEqual(
                raised.exception.code, "ADOPTION_CONFIRMATION_REQUIRED"
            )
            marker, instance_id, adopting = self.manager._collision_preflight(
                self.invocation(confirmation=ADOPT_CONFIRMATION)
            )
        self.assertIsNone(marker)
        self.assertTrue(adopting)
        uuid.UUID(instance_id)

    def test_archive_member_rejects_traversal_and_links(self) -> None:
        traversal = tarfile.TarInfo("forgejo-backup/../../escape")
        link = tarfile.TarInfo("forgejo-backup/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "../../escape"
        safe = tarfile.TarInfo("forgejo-backup/database.dump")
        self.assertFalse(self.manager._safe_archive_member(traversal))
        self.assertFalse(self.manager._safe_archive_member(link))
        self.assertTrue(self.manager._safe_archive_member(safe))

    def test_backup_destination_rejects_product_state(self) -> None:
        invocation = self.invocation(
            "backup",
            inputs={
                "backup_destination": str(self.paths.state_root / "backup")
            },
        )
        with self.assertRaises(ManagementError) as raised:
            self.manager._backup_destination(invocation)
        self.assertEqual(
            raised.exception.code, "INVALID_BACKUP_DESTINATION"
        )


if __name__ == "__main__":
    unittest.main()
