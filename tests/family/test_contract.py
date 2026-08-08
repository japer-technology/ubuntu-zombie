from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

from conformance import (
    ContractError,
    OPERATIONS,
    load_json_strict,
    validate_product,
    validate_response,
)

ROOT = Path(__file__).resolve().parents[2]
FRIEND_PRODUCT = ROOT / "products" / "imaginary-friend"
LLAMA_PRODUCT = ROOT / "products" / "llama"


class FamilyContractTests(unittest.TestCase):
    def test_every_schema_is_strict_json(self) -> None:
        schemas = ROOT / "family" / "schemas"
        expected = {
            "audit-event-v1.schema.json",
            "catalog-v1.schema.json",
            "installation-v1.schema.json",
            "inventory-v1.schema.json",
            "product-v1.schema.json",
            "receipt-v1.schema.json",
            "request-v1.schema.json",
            "response-v1.schema.json",
        }
        self.assertEqual({path.name for path in schemas.glob("*.json")}, expected)
        for path in schemas.glob("*.json"):
            value = load_json_strict(path)
            self.assertEqual(
                value["$schema"], "https://json-schema.org/draft/2020-12/schema"
            )
            self.assertEqual(value["type"], "object")

    def test_catalog_is_empty_until_release_gates_pass(self) -> None:
        catalog = load_json_strict(ROOT / "family" / "catalog.json")
        self.assertEqual(
            set(catalog), {"schema_version", "repository", "generated_at", "products"}
        )
        self.assertEqual(catalog["schema_version"], 1)
        self.assertEqual(catalog["repository"], "japer-technology/ubuntu-zombie")
        self.assertEqual(catalog["products"], [])

    def test_imaginary_friend_descriptor(self) -> None:
        descriptor = load_json_strict(FRIEND_PRODUCT / "PRODUCT.json")
        validate_product(descriptor)
        self.assertEqual(descriptor["product_id"], "imaginary-friend")
        self.assertEqual(descriptor["operations"], list(OPERATIONS))
        self.assertEqual(descriptor["cookie_names"], ["imaginary_friend_session"])
        self.assertEqual(descriptor["ports"][0]["port"], 6767)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        path = ROOT / "tests" / "family" / ".duplicate-test.json"
        try:
            path.write_text('{"schema_version":1,"schema_version":2}', encoding="utf-8")
            with self.assertRaises(ContractError):
                load_json_strict(path)
        finally:
            path.unlink(missing_ok=True)

    def test_llama_descriptor(self) -> None:
        descriptor = load_json_strict(LLAMA_PRODUCT / "PRODUCT.json")
        validate_product(descriptor)
        self.assertEqual(descriptor["product_id"], "llama")
        self.assertEqual(descriptor["operations"], list(OPERATIONS))
        self.assertEqual(descriptor["cookie_names"], [])
        self.assertEqual(descriptor["ports"][0]["port"], 8080)

    def test_manage_describe_uses_common_response(self) -> None:
        for product in (FRIEND_PRODUCT, LLAMA_PRODUCT):
            with self.subTest(product=product.name):
                completed = subprocess.run(
                    [str(product / "scripts" / "manage.sh"), "describe", "--json"],
                    cwd=ROOT,
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                response = json.loads(completed.stdout)
                validate_response(response)
                self.assertEqual(response["operation"], "describe")
                self.assertEqual(response["status"], "ok")

    def test_friend_is_not_a_zombie_component(self) -> None:
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertNotIn("imaginary-friend", installer)
        self.assertNotIn("friend-manage", installer)

    def test_llama_root_targets_are_delegating_shims_only(self) -> None:
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        uninstaller = (ROOT / "scripts" / "uninstall.sh").read_text(encoding="utf-8")
        self.assertIn("llama_product_manage", installer)
        self.assertIn("llama_product_manage", uninstaller)
        for name in (
            "install_llama",
            "verify_llama",
            "doctor_llama",
            "repair_llama",
            "assert_llama_installation_safe",
        ):
            self.assertIsNone(re.search(rf"(?m)^{name}\(\)", installer))
        self.assertIsNone(re.search(r"systemctl .*llama-server", uninstaller))
        self.assertIsNone(re.search(r"remove_tree_checked .*llama\.cpp", uninstaller))
        for path in (
            ROOT / "payload/bin/llama-manager",
            ROOT / "payload/etc/llama-builds.json",
            ROOT / "payload/etc/llama-models.json",
            ROOT / "payload/systemd/llama-server.service",
        ):
            self.assertFalse(path.exists(), path)


if __name__ == "__main__":
    unittest.main()
