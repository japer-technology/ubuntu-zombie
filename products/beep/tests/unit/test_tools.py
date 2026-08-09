from __future__ import annotations

import unittest

import family
import tools


class FamilyToolTests(unittest.TestCase):
    def test_agent_plan_only_admits_mutating_target_operations(self) -> None:
        operations = set(
            tools.TOOL_REGISTRY["agent.plan"]["schema"]["properties"]["operation"][
                "enum"
            ]
        )
        self.assertEqual(operations, set(family.MUTATING_OPERATIONS))
        self.assertTrue(
            operations.isdisjoint({"describe", "status", "verify", "doctor"})
        )


if __name__ == "__main__":
    unittest.main()
