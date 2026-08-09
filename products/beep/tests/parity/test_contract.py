from __future__ import annotations

import json
import unittest
from pathlib import Path


PRODUCT_ROOT = Path(__file__).resolve().parents[2]


class ProductParityTests(unittest.TestCase):
    def test_descriptor_matches_owned_contract_fixture(self) -> None:
        descriptor = json.loads(
            (PRODUCT_ROOT / "PRODUCT.json").read_text(encoding="utf-8")
        )
        fixture = json.loads(
            (
                Path(__file__).with_name("fixtures")
                / "beep-contract-v1.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(descriptor["product_id"], fixture["product_id"])
        for name in (
            "install_root",
            "configuration_root",
            "state_root",
            "log_root",
        ):
            self.assertEqual(descriptor[name], fixture[name])
        self.assertEqual(descriptor["ports"][0]["port"], fixture["port"])
        self.assertEqual(descriptor["cookie_names"], [fixture["cookie"]])
        self.assertEqual(descriptor["units"], fixture["units"])
        self.assertEqual(descriptor["operations"], fixture["operations"])

    def test_terminal_lifecycle_stops_periodic_health_work(self) -> None:
        timer = (
            PRODUCT_ROOT / "payload" / "systemd" / "beep-health.timer"
        ).read_text(encoding="utf-8")
        self.assertIn("BindsTo=beep-chat.service", timer)
        self.assertIn("After=beep-chat.service", timer)

    def test_release_lookup_uses_authoritative_repository(self) -> None:
        server = (
            PRODUCT_ROOT / "payload" / "agent" / "server.py"
        ).read_text(encoding="utf-8")
        self.assertIn("ubuntu-zombie/releases?per_page=100", server)
        self.assertNotIn("beep/releases/latest", server)


if __name__ == "__main__":
    unittest.main()
