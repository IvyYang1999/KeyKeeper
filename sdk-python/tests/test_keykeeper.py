import subprocess
import unittest
from unittest.mock import patch, MagicMock
from keykeeper import list_credentials, get_field, get_key, run, KeyKeeperError


def _mock_cli_found():
    """Patch _find_cli so it returns a dummy path without checking the filesystem."""
    return patch("keykeeper._find_cli", return_value="/usr/local/bin/keykeeper")


class TestListCredentials(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_list_parses_output(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="stripe | Stripe API\n\nopenai | OpenAI\n\n",
            returncode=0,
        )
        with _mock_cli_found():
            result = list_credentials()
        self.assertEqual(result, ["stripe", "openai"])

    @patch("keykeeper.subprocess.run")
    def test_list_empty(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="No credentials stored. Use the KeyKeeper app to add credentials.\n",
            returncode=0,
        )
        with _mock_cli_found():
            result = list_credentials()
        self.assertEqual(result, [])


class TestGetField(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_get_field_returns_value(self, mock_run):
        mock_run.return_value = MagicMock(stdout="cli_abc123", returncode=0)
        with _mock_cli_found():
            result = get_field("feishu", "app_id")
        self.assertEqual(result, "cli_abc123")
        mock_run.assert_called_once_with(
            ["/usr/local/bin/keykeeper", "get", "feishu", "app_id"],
            capture_output=True,
            text=True,
        )

    @patch("keykeeper.subprocess.run")
    def test_get_field_not_found(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="", stderr="Error: Credential 'x' not found", returncode=1
        )
        with _mock_cli_found():
            with self.assertRaises(KeyKeeperError):
                get_field("x", "y")


class TestGetKey(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_get_key_returns_secret(self, mock_run):
        mock_run.return_value = MagicMock(stdout="sk_live_xxx", returncode=0)
        with _mock_cli_found():
            result = get_key("stripe", "api_key")
        self.assertEqual(result, "sk_live_xxx")


class TestRun(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_multiple_credentials_and_prefix_keep_cli_shape(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)

        with _mock_cli_found():
            result = run(
                ["first", "second"],
                ["python", "script.py"],
                prefix="KEYKEEPER_",
                verbose=True,
            )

        self.assertEqual(result.returncode, 0)
        mock_run.assert_called_once_with([
            "/usr/local/bin/keykeeper",
            "run",
            "-c", "first",
            "-c", "second",
            "--prefix", "KEYKEEPER_",
            "--verbose",
            "--",
            "python", "script.py",
        ])


if __name__ == "__main__":
    unittest.main()
