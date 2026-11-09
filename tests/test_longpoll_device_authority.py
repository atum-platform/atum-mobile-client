"""Candidate authority refusal happens before any CoreDevice operation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class DeviceBoundaryReached(Exception):
    pass


class LongpollDeviceAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Synthetic.app"
        self.app.mkdir()
        for name in ("AtumMobile", "AtumMobile.debug.dylib"):
            (self.app / name).write_bytes(b"synthetic executable fixture " + name.encode())
        for pack in ("custody", "longpoll-ownership"):
            manifest = self.root / "sdk" / pack / "source.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"syntheticAuthority": pack}))
        self.receipt = self.root / "candidate.json"

    def module(self, script):
        spec = importlib.util.spec_from_file_location(script, ROOT / "scripts" / script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.ROOT = self.root
        return module

    def record(self, pack, **changes):
        record = {"status": "SIGNED_DEBUG_BUILD_ONLY", "mainProjectKeepsOriginalSDK": True,
                  "consumerHasUncommittedChanges": False,
                  "sourceManifestSHA256": hashlib.sha256((self.root / "sdk" / pack / "source.json").read_bytes()).hexdigest(),
                  "sourceSHA256": {},
                  **{key: hashlib.sha256((self.app / file).read_bytes()).hexdigest() for key, file in
                     (("appExecutableSHA256", "AtumMobile"), ("appDebugDylibSHA256", "AtumMobile.debug.dylib"))}}
        if pack == "longpoll-ownership":
            record.update(unselectedLongpollOwnership=True, runtimeSelected=False)
        record.update(changes)
        self.receipt.write_text(json.dumps(record))

    def run_to_boundary(self, script, opt_in, record_pack, expect_accept, **changes):
        module = self.module(script)
        self.record(record_pack, **changes)
        args = SimpleNamespace(app=self.app, candidate_receipt=self.receipt,
                               unselected_longpoll_ownership=opt_in,
                               recovery=True, bound=False, sdk_existing=True, sdk_session=False)
        calls = []

        def command(argv, **kwargs):
            calls.append(argv)
            if argv[0] == "codesign":
                return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
            if argv[:2] == ["xcrun", "devicectl"]:
                raise DeviceBoundaryReached()
            raise AssertionError("Unexpected external command")

        with patch.object(module.subprocess, "run", side_effect=command):
            with self.assertRaises(DeviceBoundaryReached if expect_accept else SystemExit):
                module.run(args)
        self.assertEqual(expect_accept, any(argv[0] == "xcrun" for argv in calls))

    def test_each_collector_accepts_custody_by_default_and_longpoll_only_explicitly(self):
        for script in ("probe-domain-keychain.py", "probe-public-discovery.py"):
            for opt_in, pack in ((False, "custody"), (True, "longpoll-ownership")):
                with self.subTest(script=script, opt_in=opt_in):
                    self.run_to_boundary(script, opt_in, pack, True)

    def test_swapped_source_authorities_are_refused_before_device(self):
        for script in ("probe-domain-keychain.py", "probe-public-discovery.py"):
            for opt_in, pack in ((False, "longpoll-ownership"), (True, "custody")):
                with self.subTest(script=script, opt_in=opt_in):
                    self.run_to_boundary(script, opt_in, pack, False)

    def test_selected_dirty_missing_marker_wrong_manifest_and_binary_are_refused(self):
        changes = [{"runtimeSelected": True}, {"consumerHasUncommittedChanges": True},
                   {"unselectedLongpollOwnership": False}, {"sourceManifestSHA256": "0" * 64},
                   {"appExecutableSHA256": "0" * 64}]
        for script in ("probe-domain-keychain.py", "probe-public-discovery.py"):
            for mutation in changes:
                with self.subTest(script=script, mutation=mutation):
                    self.run_to_boundary(script, True, "longpoll-ownership", False, **mutation)

    def test_changed_source_file_is_refused_before_device(self):
        (self.root / "source.swift").write_text("changed synthetic source")
        for script in ("probe-domain-keychain.py", "probe-public-discovery.py"):
            with self.subTest(script=script):
                self.run_to_boundary(script, True, "longpoll-ownership", False,
                                     sourceSHA256={"source.swift": "0" * 64})

    def test_unselected_option_cannot_change_non_candidate_modes(self):
        for script in ("probe-domain-keychain.py", "probe-public-discovery.py"):
            module = self.module(script)
            args = SimpleNamespace(unselected_longpoll_ownership=True, recovery=False, sdk_existing=False)
            with self.subTest(script=script), patch.object(module.subprocess, "run") as command:
                with self.assertRaises(SystemExit):
                    module.run(args)
                command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
