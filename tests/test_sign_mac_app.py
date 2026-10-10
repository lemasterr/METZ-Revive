import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("metz_signing", Path(__file__).resolve().parents[1] / "scripts/sign_mac_app.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningSelectionCheck(unittest.TestCase):
    def test_unique_valid_identity(self):
        output = '  1) ' + 'A' * 40 + ' "Apple Development: Test"\n  1 valid identities found\n'
        self.assertEqual(signing.choose_identity(output), 'A' * 40)

    def test_no_identity_never_silently_falls_back_to_adhoc(self):
        with self.assertRaises(ValueError):
            signing.choose_identity('  0 valid identities found\n')

    def test_multiple_identities_require_explicit_selection(self):
        output = '1) ' + 'A' * 40 + ' "First"\n2) ' + 'B' * 40 + ' "Second"\n'
        with self.assertRaises(ValueError):
            signing.choose_identity(output)
        self.assertEqual(signing.choose_identity(output, 'b' * 40), 'B' * 40)
        with self.assertRaises(ValueError):
            signing.choose_identity(output, 'C' * 40)

    def test_invalid_certificate_is_excluded(self):
        with self.assertRaises(ValueError):
            signing.choose_identity('1) ' + 'A' * 40 + ' "Test" (CSSMERR_TP_CERT_EXPIRED)\n')


if __name__ == "__main__":
    unittest.main()
