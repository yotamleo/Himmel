#!/usr/bin/env python3
"""Fixture-only checks: unrelated keys must never reach a consumer's environment."""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import dotenv

ROOT = Path(__file__).resolve().parents[2]


def module_at(path):
    spec = importlib.util.spec_from_file_location(path.stem.replace('-', '_'), path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DotenvConsumers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name) / '.env'
        self.fixture.write_text(
            'ubuntu_vm_user=fixture-user\nubuntu_vm_pass=dummy-ubuntu\n'
            'windows_vm_user=fixture-windows\nwindows_vm_pass=dummy-windows\n'
            'TEST_ANTHROPIC_API_KEY=dummy-test\nUNRELATED_API_KEY=dummy-other\n'
        )

    def assert_no_unlisted_keys(self):
        self.assertNotIn('TEST_ANTHROPIC_API_KEY', os.environ)
        self.assertNotIn('UNRELATED_API_KEY', os.environ)

    def test_consumer_keys_still_load_vmsdk(self):
        # Import does not load .env; only the VM construction path does.
        sys.path.insert(0, str(ROOT / 'scripts/lib'))
        self.addCleanup(lambda: sys.path.remove(str(ROOT / 'scripts/lib')))
        module = module_at(ROOT / 'scripts/lib/vmsdk.py')
        with patch.dict(os.environ, {}, clear=True), patch.object(module, '_env_path', return_value=self.fixture):
            # A real registry-selected consumer must load only its two keys.
            registry = {'fixture': {'os': 'ubuntu', 'ssh_port': 2222, 'user_env': 'ubuntu_vm_user', 'pass_env': 'ubuntu_vm_pass'}}
            with patch.object(module, '_load_registry', return_value=registry):
                vm = module.VM('fixture')
            self.assertEqual(vm.user, 'fixture-user')
            self.assertEqual(vm.password, 'dummy-ubuntu')
            self.assertNotIn('windows_vm_pass', os.environ)
            self.assert_no_unlisted_keys()

    def test_consumer_keys_still_load_cloudinit(self):
        module = module_at(ROOT / 'scripts/machine-setup/make-cloudinit-seed.py')
        with patch.dict(os.environ, {}, clear=True), patch.object(module, '_env_path', return_value=self.fixture):
            module._load_dotenv()
            self.assertEqual(os.environ['ubuntu_vm_user'], 'fixture-user')
            self.assertEqual(os.environ['ubuntu_vm_pass'], 'dummy-ubuntu')
            self.assertNotIn('windows_vm_pass', os.environ)
            self.assert_no_unlisted_keys()

    def test_consumer_keys_still_load_provisioners(self):
        for platform in ('ubuntu', 'windows'):
            with self.subTest(platform=platform), patch.dict(os.environ, {}, clear=True), patch.object(dotenv, 'find_dotenv', return_value=str(self.fixture)), patch.object(dotenv.main, 'find_dotenv', return_value=str(self.fixture)):
                module = module_at(ROOT / f'scripts/machine-setup/{platform}-vm-setup.py')
                self.assertEqual(module.USER, 'fixture-user' if platform == 'ubuntu' else 'fixture-windows')
                self.assertEqual(module.PASS, f'dummy-{platform}')
                other = 'windows' if platform == 'ubuntu' else 'ubuntu'
                self.assertNotIn(f'{other}_vm_pass', os.environ)
                self.assert_no_unlisted_keys()


if __name__ == '__main__':
    unittest.main()
