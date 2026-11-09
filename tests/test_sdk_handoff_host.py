"""Reject provenance mutations without building, selecting or running the SDK."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('handoff_host', ROOT / 'scripts/sdk_handoff_host.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HandoffHostProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old_root = MODULE.ROOT
        MODULE.ROOT = self.root
        self.addCleanup(setattr, MODULE, 'ROOT', self.old_root)
        self.pack = self.root / 'sdk/operation-handoff'
        self.pack.mkdir(parents=True)
        (self.pack / 'LICENSE').write_text('Synthetic Apache notice fixture')
        (self.pack / 'operation-handoff.patch').write_text('Synthetic patch fixture')
        backup = self.root / 'sdk/background-backup/operation-source.json'
        backup.parent.mkdir(parents=True)
        backup.write_text('{}')
        custody = self.root / 'sdk/custody/source.json'
        custody.parent.mkdir(parents=True)
        custody.write_text(json.dumps({'upstreamRevision': 'a' * 40}))
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'LICENSE').write_bytes((self.pack / 'LICENSE').read_bytes())
        (self.source / 'library.rs').write_text('synthetic test source')
        self.pin = {'status': 'SOURCE_OPERATION_HANDOFF_INCOMPLETE_NOT_RUNTIME_SELECTED',
                    'runtimeSelected': False, 'upstreamRevision': 'a' * 40,
                    'baseBackupOperationManifestSHA256': MODULE.digest(backup),
                    'patch': 'sdk/operation-handoff/operation-handoff.patch',
                    'patchSHA256': MODULE.digest(self.pack / 'operation-handoff.patch'),
                    'licenseSHA256': MODULE.digest(self.pack / 'LICENSE'),
                    'unchangedSourceSHA256': {'LICENSE': MODULE.digest(self.source / 'LICENSE')},
                    'prototypeSHA256': {'library.rs': MODULE.digest(self.source / 'library.rs')}}
        self.write_pin()
        self.artifact = self.root / 'artifact'
        self.artifact.mkdir()
        for name, data in {'LICENSE': (self.pack / 'LICENSE').read_bytes(),
                           'Package.swift': b'synthetic package',
                           'Sources/MatrixRustSDK/matrix_sdk_ffi.swift': b'synthetic binding',
                           'MatrixSDKFFI.xcframework/Info.plist': plistlib.dumps({'AvailableLibraries': [
                               {'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']}]}),
                           'MatrixSDKFFI.xcframework/macos-arm64/library.a': b'synthetic binary'}.items():
            p = self.artifact / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        self.receipt = {'status': 'UNSELECTED_HOST_LIBRARY_AND_SWIFT_COMPILED',
                        'runtimeSelected': False, 'targets': ['aarch64-apple-darwin'], 'versionBaseRevision': 'a' * 40,
                        'source': {'status': 'UNSELECTED_HOST_SOURCE_VERIFIED', 'runtimeSelected': False,
                                   'sourceManifestSHA256': MODULE.digest(MODULE.manifest_path()),
                                   'upstreamRevision': 'a' * 40, 'consumerRevision': 'b' * 40,
                                   'consumerHasUncommittedChanges': False},
                        'artifactSHA256': self.artifact_inventory()}
        self.write_receipt()

    def write_pin(self):
        MODULE.manifest_path().write_text(json.dumps(self.pin))

    def write_receipt(self):
        (self.artifact / 'atum-build-receipt.json').write_text(json.dumps(self.receipt))

    def artifact_inventory(self):
        return {str(p.relative_to(self.artifact)): MODULE.digest(p) for p in self.artifact.rglob('*')
                if p.is_file() and p.name != 'atum-build-receipt.json'}

    def test_valid_source_and_host_receipt_verify_without_selection(self):
        MODULE.verify_source(self.source)
        receipt, _ = MODULE.verify_artifact(self.artifact)
        self.assertFalse(receipt['runtimeSelected'])

    def test_changed_or_extra_source_is_refused(self):
        (self.source / 'library.rs').write_text('tampered')
        with self.assertRaises(ValueError):
            MODULE.verify_source(self.source)
        (self.source / 'library.rs').write_text('synthetic test source')
        (self.source / 'unexpected-build.rs').write_text('not pinned')
        with self.assertRaises(ValueError):
            MODULE.verify_source(self.source)

    def test_source_symlink_is_refused(self):
        (self.source / 'library.rs').unlink()
        (self.source / 'library.rs').symlink_to(self.source / 'LICENSE')
        with self.assertRaises(ValueError):
            MODULE.verify_source(self.source)

    def test_exact_upstream_links_are_accepted_and_other_targets_refused(self):
        target = self.source / '.cargo/mermaid.html'
        target.parent.mkdir()
        target.write_text('synthetic pinned documentation')
        self.pin['unchangedSourceSHA256']['.cargo/mermaid.html'] = MODULE.digest(target)
        for name, link_target in MODULE.SOURCE_LINKS.items():
            link = self.source / name
            link.parent.mkdir(parents=True)
            link.symlink_to(link_target)
            self.pin['unchangedSourceSHA256'][name] = MODULE.digest(target)
        self.write_pin()
        MODULE.verify_source(self.source)
        link = self.source / next(iter(MODULE.SOURCE_LINKS))
        link.unlink()
        link.symlink_to(target)
        with self.assertRaises(ValueError):
            MODULE.verify_source(self.source)

    def test_manifest_authority_mutations_are_refused(self):
        original = copy.deepcopy(self.pin)
        for field, value in [('runtimeSelected', True), ('upstreamRevision', 'c' * 40),
                             ('baseBackupOperationManifestSHA256', '0' * 64),
                             ('patchSHA256', '0' * 64), ('licenseSHA256', '0' * 64)]:
            with self.subTest(field=field):
                self.pin = copy.deepcopy(original)
                self.pin[field] = value
                self.write_pin()
                with self.assertRaises(ValueError):
                    MODULE.load_pin()
        self.pin = original
        self.write_pin()

    def test_unsafe_inventory_path_is_refused(self):
        self.pin['prototypeSHA256'] = {'../escape.rs': '0' * 64}
        self.write_pin()
        with self.assertRaises(ValueError):
            MODULE.load_pin()

    def test_selected_wrong_target_or_custody_receipt_is_refused(self):
        original = copy.deepcopy(self.receipt)
        for field, value in [('runtimeSelected', True), ('targets', ['aarch64-apple-ios']),
                             ('status', 'APPLE_LIBRARY_AND_SWIFT_COMPILED'), ('versionBaseRevision', 'c' * 40)]:
            with self.subTest(field=field):
                self.receipt = copy.deepcopy(original)
                self.receipt[field] = value
                self.write_receipt()
                with self.assertRaises(ValueError):
                    MODULE.verify_artifact(self.artifact)

    def test_bad_source_receipt_and_dirty_consumer_are_refused(self):
        original = copy.deepcopy(self.receipt)
        for field, value in [('sourceManifestSHA256', '0' * 64), ('runtimeSelected', True),
                             ('upstreamRevision', 'c' * 40), ('consumerHasUncommittedChanges', True),
                             ('status', 'SOURCE_PREPARED')]:
            with self.subTest(field=field):
                self.receipt = copy.deepcopy(original)
                self.receipt['source'][field] = value
                self.write_receipt()
                with self.assertRaises(ValueError):
                    MODULE.verify_artifact(self.artifact)

    def test_tampered_artifact_is_refused(self):
        (self.artifact / 'MatrixSDKFFI.xcframework/macos-arm64/library.a').write_text('tampered')
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_different_license_is_refused_even_if_rehashed(self):
        (self.artifact / 'LICENSE').write_text('different notice')
        self.receipt['artifactSHA256'] = self.artifact_inventory()
        self.write_receipt()
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_wrong_platform_is_refused_even_if_rehashed(self):
        p = self.artifact / 'MatrixSDKFFI.xcframework/Info.plist'
        p.write_bytes(plistlib.dumps({'AvailableLibraries': [
            {'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64']}]}))
        self.receipt['artifactSHA256'] = self.artifact_inventory()
        self.write_receipt()
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def install_longpoll_fixture(self):
        pack = self.root / 'sdk/longpoll-ownership'
        pack.mkdir()
        (pack / 'LICENSE').write_bytes((self.pack / 'LICENSE').read_bytes())
        (pack / 'longpoll-ownership.patch').write_text('Synthetic long-poll delta fixture')
        (self.source / 'library.rs').write_text('synthetic long-poll source')
        pin = {'status': 'SOURCE_LONGPOLL_OWNERSHIP_INCOMPLETE_NOT_RUNTIME_SELECTED',
               'runtimeSelected': False, 'upstreamRevision': self.pin['upstreamRevision'],
               'baseOperationHandoffManifestSHA256': MODULE.digest(MODULE.manifest_path()),
               'patch': 'sdk/longpoll-ownership/longpoll-ownership.patch',
               'patchSHA256': MODULE.digest(pack / 'longpoll-ownership.patch'),
               'licenseSHA256': self.pin['licenseSHA256'],
               'preimageSHA256': self.pin['prototypeSHA256'].copy(),
               'prototypeSHA256': {'library.rs': MODULE.digest(self.source / 'library.rs')},
               'unchangedSourceSHA256': self.pin['unchangedSourceSHA256'].copy()}
        MODULE.manifest_path('longpoll-ownership').write_text(json.dumps(pin))
        return pin

    def test_new_pack_requires_explicit_matching_artifact_authority(self):
        self.install_longpoll_fixture()
        MODULE.verify_source(self.source, 'longpoll-ownership')
        with self.assertRaises(ValueError):
            MODULE.verify_source(self.source)
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact, 'longpoll-ownership')
        self.receipt['source']['sourceManifestSHA256'] = MODULE.digest(
            MODULE.manifest_path('longpoll-ownership'))
        self.write_receipt()
        MODULE.verify_artifact(self.artifact, 'longpoll-ownership')
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_new_pack_rejects_changed_parent_preimage_and_inventory(self):
        pin = self.install_longpoll_fixture()
        mutations = [('baseOperationHandoffManifestSHA256', '0' * 64),
                     ('preimageSHA256', {'library.rs': '0' * 64}),
                     ('unchangedSourceSHA256', {'LICENSE': '0' * 64}),
                     ('prototypeSHA256', {'unexpected.rs': '0' * 64}),
                     ('runtimeSelected', True)]
        for field, value in mutations:
            with self.subTest(field=field):
                changed = copy.deepcopy(pin)
                changed[field] = value
                MODULE.manifest_path('longpoll-ownership').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    MODULE.load_pin('longpoll-ownership')

    def test_new_pack_revalidates_parent_and_rejects_unknown_authority(self):
        pin = self.install_longpoll_fixture()
        self.pin['runtimeSelected'] = True
        self.write_pin()
        pin['baseOperationHandoffManifestSHA256'] = MODULE.digest(MODULE.manifest_path())
        MODULE.manifest_path('longpoll-ownership').write_text(json.dumps(pin))
        with self.assertRaises(ValueError):
            MODULE.load_pin('longpoll-ownership')
        with self.assertRaises(ValueError):
            MODULE.manifest_path('untrusted')


if __name__ == '__main__':
    unittest.main()
