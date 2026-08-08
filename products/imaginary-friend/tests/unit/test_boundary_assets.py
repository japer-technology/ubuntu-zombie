from __future__ import annotations

import json
import unittest
from pathlib import Path


PRODUCT_ROOT = Path(__file__).resolve().parents[2]


class BoundaryAssetTests(unittest.TestCase):
    def test_policy_exposes_only_friend_capabilities(self) -> None:
        policy = json.loads(
            (PRODUCT_ROOT / "payload" / "etc" / "policy.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            set(policy["capabilities"]),
            {
                "conversation",
                "workspace.read",
                "workspace.change",
                "product.admin",
            },
        )
        self.assertEqual(
            set(policy["absent"]),
            {
                "account",
                "host-inspection",
                "network-tool",
                "package",
                "service",
                "shell",
                "sibling",
                "sudo",
            },
        )

    def test_service_asset_keeps_structural_denials(self) -> None:
        unit = (
            PRODUCT_ROOT
            / "payload"
            / "systemd"
            / "imaginary-friend-chat.service"
        ).read_text(encoding="utf-8")
        for required in (
            "User=friend",
            "SupplementaryGroups=friend-share",
            "NoNewPrivileges=true",
            "ProtectSystem=strict",
            "ProtectHome=true",
            "CapabilityBoundingSet=",
            "IPAddressDeny=any",
            "IPAddressAllow=localhost",
            "InaccessiblePaths=/opt/ai-zombie",
            "InaccessiblePaths=/opt/curriculum-flame",
            "InaccessiblePaths=/opt/eric",
            "InaccessiblePaths=/usr/bin/sudo",
            "InaccessiblePaths=/usr/bin/bash",
        ):
            self.assertIn(required, unit)
        self.assertNotIn("ExecStart=/bin/", unit)


if __name__ == "__main__":
    unittest.main()
