from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))

from openai_fixture import Fixture  # noqa: E402

from friend.errors import ValidationError
from friend.model import ModelClient, validate_model_base_url


class ModelTests(unittest.TestCase):
    def test_loopback_fixture_supports_bounded_probe_and_completion(self) -> None:
        with Fixture() as fixture:
            client = ModelClient(fixture.base_url, "fixture-friend")
            self.assertEqual(client.models(), ["fixture-friend"])
            self.assertTrue(client.probe()["completion"])
            self.assertEqual(
                client.complete([{"role": "user", "content": "hello"}]),
                "A private fixture reply.",
            )

    def test_non_loopback_credentials_and_non_http_are_rejected(self) -> None:
        for value in (
            "https://127.0.0.1:8080/v1",
            "http://example.com/v1",
            "http://" + "user" + ":" + "pass" + "@127.0.0.1:8080/v1",
            "http://169.254.169.254/v1",
            "file:///tmp/model",
        ):
            with self.assertRaises(ValidationError, msg=value):
                validate_model_base_url(value)


if __name__ == "__main__":
    unittest.main()
