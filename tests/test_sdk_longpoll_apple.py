"""Provenance-only tests for the unselected long-poll Apple candidate."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'sdk_longpoll_apple', ROOT / 'scripts/sdk_longpoll_apple.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LongpollAppleProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old_root = MODULE.ROOT
        self.old_host_root = MODULE.HOST.ROOT
        MODULE.ROOT = self.root
        MODULE.HOST.ROOT = self.root
        self.addCleanup(setattr, MODULE, 'ROOT', self.old_root)
        self.addCleanup(setattr, MODULE.HOST, 'ROOT', self.old_host_root)
        self._write_authorities()
        self._write_artifact()

    def _write_authorities(self):
        custody = self.root / 'sdk/custody/source.json'
        custody.parent.mkdir(parents=True)
        custody.write_text(json.dumps({'upstreamRevision': 'a' * 40}))
        self.operation = self.root / 'sdk/operation-handoff'
        self.operation.mkdir()
        (self.operation / 'LICENSE').write_text('Synthetic Apache notice')
        (self.operation / 'operation-handoff.patch').write_text('operation patch')
        backup = self.root / 'sdk/background-backup/operation-source.json'
        backup.parent.mkdir(parents=True)
        backup.write_text('{}')
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'LICENSE').write_bytes((self.operation / 'LICENSE').read_bytes())
        (self.source / 'library.rs').write_text('long-poll original')
        self.parent_pin = {
            'status': 'SOURCE_OPERATION_HANDOFF_INCOMPLETE_NOT_RUNTIME_SELECTED',
            'runtimeSelected': False,
            'upstreamRevision': 'a' * 40,
            'baseBackupOperationManifestSHA256': MODULE.HOST.digest(backup),
            'patch': 'sdk/operation-handoff/operation-handoff.patch',
            'patchSHA256': MODULE.HOST.digest(self.operation / 'operation-handoff.patch'),
            'licenseSHA256': MODULE.HOST.digest(self.operation / 'LICENSE'),
            'unchangedSourceSHA256': {'LICENSE': MODULE.HOST.digest(self.source / 'LICENSE')},
            'prototypeSHA256': {'library.rs': MODULE.HOST.digest(self.source / 'library.rs')},
        }
        (self.operation / 'source.json').write_text(json.dumps(self.parent_pin))
        self.longpoll = self.root / 'sdk/longpoll-ownership'
        self.longpoll.mkdir()
        (self.longpoll / 'LICENSE').write_bytes((self.operation / 'LICENSE').read_bytes())
        (self.longpoll / 'longpoll-ownership.patch').write_text('long-poll patch')
        (self.source / 'library.rs').write_text('long-poll ownership correction')
        self.pin = {
            'status': 'SOURCE_LONGPOLL_OWNERSHIP_INCOMPLETE_NOT_RUNTIME_SELECTED',
            'runtimeSelected': False,
            'upstreamRevision': 'a' * 40,
            'baseOperationHandoffManifestSHA256': MODULE.HOST.digest(self.operation / 'source.json'),
            'patch': 'sdk/longpoll-ownership/longpoll-ownership.patch',
            'patchSHA256': MODULE.HOST.digest(self.longpoll / 'longpoll-ownership.patch'),
            'licenseSHA256': MODULE.HOST.digest(self.longpoll / 'LICENSE'),
            'preimageSHA256': self.parent_pin['prototypeSHA256'].copy(),
            'prototypeSHA256': {'library.rs': MODULE.HOST.digest(self.source / 'library.rs')},
            'unchangedSourceSHA256': self.parent_pin['unchangedSourceSHA256'].copy(),
        }
        MODULE.manifest_path().write_text(json.dumps(self.pin))

    def _write_artifact(self):
        self.artifact = self.root / 'artifact'
        self.artifact.mkdir()
        files = {
            'LICENSE': (self.longpoll / 'LICENSE').read_bytes(),
            'Package.swift': b'// plain generated package\n',
            'Sources/MatrixRustSDK/matrix_sdk_ffi.swift': b'func restoreSessionExisting() {}\n',
            'MatrixSDKFFI.xcframework/ios-arm64/libmatrix_sdk_ffi.a': b'ios arm64',
            'MatrixSDKFFI.xcframework/macos-arm64/libmatrix_sdk_ffi.a': b'macos arm64',
            'MatrixSDKFFI.xcframework/Info.plist': plistlib.dumps({'AvailableLibraries': [
                {'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64'],
                 'LibraryIdentifier': 'ios-arm64', 'LibraryPath': 'libmatrix_sdk_ffi.a'},
                {'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64'],
                 'LibraryIdentifier': 'macos-arm64', 'LibraryPath': 'libmatrix_sdk_ffi.a'},
            ]}),
        }
        for platform in ('ios-arm64', 'macos-arm64'):
            for header in ('base', 'common', 'crypto', 'ffi', 'sqlite', 'ui', 'events'):
                files[f'MatrixSDKFFI.xcframework/{platform}/Headers/{header}.h'] = header.encode()
        for binding in ('matrix_sdk', 'matrix_sdk_base', 'matrix_sdk_common'):
            files[f'Sources/MatrixRustSDK/{binding}.swift'] = b'// generated\n'
        for relative, contents in files.items():
            path = self.artifact / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        pin, inventory = MODULE.HOST.load_pin(MODULE.SOURCE_PACK)
        self.receipt = {
            'schemaVersion': 1,
            'status': MODULE.ARTIFACT_STATUS,
            'runtimeSelected': False,
            'targets': MODULE.TARGETS,
            'versionBaseRevision': pin['upstreamRevision'],
            'source': {
                'status': MODULE.SOURCE_STATUS,
                'runtimeSelected': False,
                'sourceManifestSHA256': MODULE.digest(MODULE.manifest_path()),
                'upstreamRevision': pin['upstreamRevision'],
                'sourceFileCount': len(inventory),
                'consumerRevision': 'b' * 40,
                'consumerHasUncommittedChanges': False,
            },
            'artifactFileCount': len(MODULE._artifact_inventory(self.artifact)),
            'artifactSHA256': MODULE._artifact_inventory(self.artifact),
        }
        self._write_receipt()

    def _write_receipt(self):
        (self.artifact / 'atum-build-receipt.json').write_text(json.dumps(self.receipt))

    def _rehash(self):
        self.receipt['artifactFileCount'] = len(MODULE._artifact_inventory(self.artifact))
        self.receipt['artifactSHA256'] = MODULE._artifact_inventory(self.artifact)
        self._write_receipt()

    def test_valid_longpoll_authority_and_two_platform_artifact_verify(self):
        self.assertEqual(MODULE.manifest_path(), self.longpoll / 'source.json')
        receipt, receipt_digest = MODULE.verify_artifact(self.artifact)
        self.assertEqual(receipt, self.receipt)
        self.assertEqual(len(receipt_digest), 64)
        self.assertFalse(receipt['runtimeSelected'])

    def test_host_default_verifier_refuses_universal_longpoll_artifact(self):
        with self.assertRaises(ValueError):
            MODULE.HOST.verify_artifact(self.artifact)

    def test_source_authority_status_selection_dirty_consumer_and_manifest_substitution_refused(self):
        original = copy.deepcopy(self.receipt)
        substitutions = [
            ('source.status', 'SOURCE_PREPARED'),
            ('source.runtimeSelected', True),
            ('source.consumerHasUncommittedChanges', True),
            ('source.sourceManifestSHA256', MODULE.HOST.digest(self.operation / 'source.json')),
            ('artifact.runtimeSelected', True),
            ('artifact.status', 'APPLE_LIBRARY_AND_SWIFT_COMPILED'),
            ('artifact.status', 'UNSELECTED_HOST_LIBRARY_AND_SWIFT_COMPILED'),
        ]
        for field, value in substitutions:
            with self.subTest(field=field):
                self.receipt = copy.deepcopy(original)
                parent, child = field.split('.')
                if parent == 'source':
                    self.receipt['source'][child] = value
                else:
                    self.receipt[child] = value
                self._write_receipt()
                with self.assertRaises(ValueError):
                    MODULE.verify_artifact(self.artifact)
        self.receipt = original
        self._write_receipt()

    def test_custody_authority_substitution_is_refused_by_host_authority(self):
        (self.root / 'sdk/custody/source.json').write_text(
            json.dumps({'upstreamRevision': 'c' * 40}))
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_wrong_extra_or_simulator_slices_are_refused_even_when_rehashed(self):
        original = (self.artifact / 'MatrixSDKFFI.xcframework/Info.plist').read_bytes()
        invalid = [
            [{'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64']}],
            [{'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64']},
             {'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']},
             {'SupportedPlatform': 'tvos', 'SupportedArchitectures': ['arm64']}],
            [{'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64'],
              'SupportedPlatformVariant': 'simulator'},
             {'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']}],
            [{'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64', 'x86_64']},
             {'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']}],
        ]
        for libraries in invalid:
            with self.subTest(libraries=libraries):
                (self.artifact / 'MatrixSDKFFI.xcframework/Info.plist').write_bytes(
                    plistlib.dumps({'AvailableLibraries': libraries}))
                self._rehash()
                with self.assertRaises(ValueError):
                    MODULE.verify_artifact(self.artifact)
        (self.artifact / 'MatrixSDKFFI.xcframework/Info.plist').write_bytes(original)

    def test_missing_or_misdirected_library_metadata_and_physical_slice_are_refused(self):
        info = self.artifact / 'MatrixSDKFFI.xcframework/Info.plist'
        original = plistlib.loads(info.read_bytes())
        for identifier, library_path in [('ios-arm64_x86_64-simulator', 'libmatrix_sdk_ffi.a'),
                                         ('ios-arm64', '../libmatrix_sdk_ffi.a')]:
            with self.subTest(identifier=identifier, library_path=library_path):
                changed = copy.deepcopy(original)
                changed['AvailableLibraries'][0]['LibraryIdentifier'] = identifier
                changed['AvailableLibraries'][0]['LibraryPath'] = library_path
                info.write_bytes(plistlib.dumps(changed))
                self._rehash()
                with self.assertRaises(ValueError):
                    MODULE.verify_artifact(self.artifact)
        info.write_bytes(plistlib.dumps(original))
        extra = self.artifact / 'MatrixSDKFFI.xcframework/ios-arm64_x86_64-simulator/libmatrix_sdk_ffi.a'
        extra.parent.mkdir()
        extra.write_bytes(b'extra architecture')
        self._rehash()
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_tampered_generated_swift_inventory_and_license_are_refused(self):
        binding = self.artifact / 'Sources/MatrixRustSDK/matrix_sdk_ffi.swift'
        original = binding.read_bytes()
        binding.write_text('func restoreSessionExisting() { tampered }\n')
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)
        binding.write_bytes(original)
        self._rehash()
        MODULE.verify_artifact(self.artifact)
        nested_receipt = self.artifact / 'nested/atum-build-receipt.json'
        nested_receipt.parent.mkdir()
        nested_receipt.write_text('unaccounted nested receipt')
        self.assertIn('nested/atum-build-receipt.json', MODULE._artifact_inventory(self.artifact))
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)
        nested_receipt.unlink()
        (self.artifact / 'LICENSE').write_text('not Apache')
        self._rehash()
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_artifact_symlinks_are_refused(self):
        path = self.artifact / 'MatrixSDKFFI.xcframework/macos-arm64/libmatrix_sdk_ffi.a'
        path.unlink()
        path.symlink_to(self.artifact / 'MatrixSDKFFI.xcframework/ios-arm64/libmatrix_sdk_ffi.a')
        with self.assertRaises(ValueError):
            MODULE.verify_artifact(self.artifact)

    def test_build_requires_clean_consumer_and_fresh_output_before_native_work(self):
        with mock.patch.object(MODULE.subprocess, 'check_output', side_effect=['c' * 40, ' M dirty']):
            with self.assertRaisesRegex(ValueError, 'committed clean consumer'):
                MODULE.build(self.source, self.root / 'new-output')
        output = self.root / 'existing-output'
        output.mkdir()
        with self.assertRaisesRegex(ValueError, 'destination must be new'):
            MODULE.build(self.source, output)


if __name__ == '__main__':
    unittest.main()
