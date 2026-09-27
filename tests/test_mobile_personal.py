import base64
import tempfile
import unittest
from pathlib import Path

from scripts import prepare_mobile_personal


class MobilePersonalDefaultsTests(unittest.TestCase):
    def test_private_build_defaults_are_local_and_owner_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = prepare_mobile_personal.ROOT
            try:
                prepare_mobile_personal.ROOT = Path(temporary)
                token_file = Path(temporary) / "token"
                token_file.write_text("test-only-secret-1234567890")
                prepare_mobile_personal.prepare("https://example.com", token_file)
                ios = Path(temporary) / "ios/PersonalDefaults.local.xcconfig"
                android = Path(temporary) / "android/personal-defaults.properties"
                self.assertEqual(ios.stat().st_mode & 0o777, 0o600)
                self.assertEqual(android.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("test-only-secret", ios.read_text())
                self.assertNotIn("test-only-secret", android.read_text())
                encoded = ios.read_text().splitlines()[1].split("=", 1)[1].strip()
                self.assertEqual(base64.b64decode(encoded).decode(), token_file.read_text())
            finally:
                prepare_mobile_personal.ROOT = original

    def test_rejects_credentials_in_server_address(self):
        with tempfile.TemporaryDirectory() as temporary:
            token_file = Path(temporary) / "token"
            token_file.write_text("test-only-secret-1234567890")
            with self.assertRaises(ValueError):
                prepare_mobile_personal.prepare("https://user:password@example.com", token_file)
