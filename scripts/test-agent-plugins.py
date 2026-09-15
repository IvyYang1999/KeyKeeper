#!/usr/bin/env python3
"""Synthetic-only plugin tests; never call the installed credential store."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import hashlib
from unittest.mock import patch
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "Plugins/keykeeper"


class PluginTests(unittest.TestCase):
    def test_packaged_resources_are_exact_and_create_only(self):
        spec = importlib.util.spec_from_file_location("package", ROOT / "scripts/package-agent-plugins.py")
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        with tempfile.TemporaryDirectory(prefix="kk-package-test-") as directory:
            destination = Path(directory) / "AgentPlugins"
            package.stage(destination)
            for copied in destination.rglob("*"):
                if copied.is_file():
                    original = ROOT / copied.relative_to(destination)
                    self.assertEqual(hashlib.sha256(copied.read_bytes()).digest(),
                                     hashlib.sha256(original.read_bytes()).digest())
            with self.assertRaises(FileExistsError):
                package.stage(destination)

    def test_safe_reference_and_version_parity(self):
        self.assertTrue((PLUGIN / "skills/keykeeper/references/safe-import.md").is_file())
        manifests = [json.loads((PLUGIN / host / "plugin.json").read_text())
                     for host in (".codex-plugin", ".claude-plugin")]
        self.assertEqual(manifests[0]["version"], manifests[1]["version"])

    def test_two_hosts_resolve_same_shared_skill(self):
        for host in (".codex-plugin", ".claude-plugin"):
            manifest = json.loads((PLUGIN / host / "plugin.json").read_text())
            self.assertEqual(manifest["name"], "keykeeper")
            self.assertTrue((PLUGIN / manifest["skills"] / "keykeeper/SKILL.md").is_file())
            self.assertFalse(set(manifest) & {"hooks", "mcpServers", "apps"})
        codex = json.loads((ROOT / ".agents/plugins/marketplace.json").read_text())
        claude = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(codex["name"], claude["name"])
        self.assertEqual((ROOT / codex["plugins"][0]["source"]["path"]).resolve(), PLUGIN)
        self.assertEqual((ROOT / claude["plugins"][0]["source"]).resolve(), PLUGIN)

    def test_readiness_is_bounded_and_does_not_return_raw_output(self):
        spec = importlib.util.spec_from_file_location("doctor", PLUGIN / "skills/keykeeper/scripts/doctor.py")
        doctor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(doctor)
        with tempfile.TemporaryDirectory(prefix="kk-plugin-test-") as directory:
            cli = Path(directory) / "fake keykeeper"
            # Synthetic marker is deliberately never safe to return as a diagnostic.
            cli.write_text('#!/bin/sh\nprintf "unexpected-SYNTHETIC-PRIVATE-output\\n"\n')
            cli.chmod(0o700)
            result = doctor.inspect(str(cli))
            self.assertEqual(result["cli"], "incompatible")
            self.assertNotIn("SYNTHETIC", json.dumps(result))
            cli.write_text('#!/bin/sh\nexec /bin/sleep 5\n')
            self.assertEqual(doctor.inspect(str(cli), timeout=0.05)["cli"], "unavailable")
        self.assertEqual(doctor.inspect("/nonexistent/keykeeper")["cli"], "missing")

    def test_readiness_allowlist_and_app_failure_classification(self):
        spec = importlib.util.spec_from_file_location("doctor", PLUGIN / "skills/keykeeper/scripts/doctor.py")
        doctor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(doctor)
        for reply, expected in [("ready", "ready"),
                                ("app not running (it starts automatically when a key is requested)", "not-running"),
                                ("SYNTHETIC-PRIVATE-error", "unavailable")]:
            outputs = ["0.3.4", "--reason", "--from-clipboard --provider --from-file", reply]
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                self.assertEqual(kwargs["timeout"], 5)
                self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                return subprocess.CompletedProcess(argv, 0, outputs.pop(0).encode())
            with patch.object(doctor.subprocess, "run", side_effect=run):
                result = doctor.inspect("/fixed/keykeeper")
            self.assertEqual(result["app"], expected)
            self.assertEqual(result["credentialAccess"], "unchecked")
            self.assertEqual(calls, [["/fixed/keykeeper", *args] for args in (
                ["--version"], ["run", "--help"], ["save", "--help"], ["status"])])
            self.assertNotIn("SYNTHETIC", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
