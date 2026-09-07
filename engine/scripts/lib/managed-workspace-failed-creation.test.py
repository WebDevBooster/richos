#!/usr/bin/env python3
"""Real raw archive/reclaim fixtures, with only OS attachment/boot substituted."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

recovery = load('managed-workspace-failed-creation')
volumes = load('managed-workspace-volume')


class FailedCreation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='failed-creation-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.provider = volumes.VolumeStore(self.root / 'private', self.root / 'active', require_root=False)
        self.ident = str(uuid.uuid4());self.boot = str(uuid.uuid4())
        self.base, self.image, *_ = self.provider._paths(self.ident)
        self.base.mkdir(mode=0o700);self.image.mkdir(mode=0o700)
        (self.image / 'bands').mkdir()
        self.data = {'Info.plist': b'not even a mountable image: preserve it',
                     'bands/0': b'latest incomplete checkout\0' * 2000,
                     'bands/1': bytes(range(256)) * 50}
        for name, value in self.data.items():
            (self.image / name).write_bytes(value)
        self.uid = os.getuid() or 501
        key = hashlib.sha256((str(self.uid) + '\0stable').encode()).hexdigest()
        self.request = dict(version=1,id=self.ident,request_key=key,request_id='stable',owner_uid=self.uid,
                            owner_gid=os.getgid(),session_id='session',source_commit='a'*40,state='creating')
        self.write_json(self.provider.root / (key + '.request.json'), self.request)
        self.raw = dict(version=1,id=self.ident,owner_uid=self.uid,owner_gid=os.getgid(),commit='a'*40,
                        state='detached',operation=None,boot_id=self.boot,
                        image_identity=[self.image.stat().st_dev,self.image.stat().st_ino])
        self.write_json(self.base / 'journal.json', self.raw)
        self.attached = False;self.busy = False;self.commands = []
        for name, function in (('_boot_id', lambda:self.boot),('_attached', self.attachment),('_run', self.run_command)):
            mock = patch.object(self.provider,name,side_effect=function);mock.start();self.addCleanup(mock.stop)
        self.auth = {'kind':'owner-cancel','session_id':'session'}

    def write_json(self, path, value):
        path.write_text(json.dumps(value));path.chmod(0o600)

    def attachment(self, image):
        return {'system-entities':[{'content-hint':'GUID_partition_scheme','dev-entry':'/dev/disk987'}]} if self.attached else None

    def run_command(self, argv):
        self.commands.append(argv)
        self.assertEqual(argv, ['/usr/bin/hdiutil','detach','/dev/disk987'])
        if self.busy:
            raise RuntimeError('busy writer holds image')
        self.attached = False
        return b''

    def recover(self, **kwargs):
        return recovery.recover_failed_creation(self.provider,self.request,authorization=kwargs.get('authorization',self.auth))

    def assert_archive(self):
        archive = self.base / 'failed-creation.tar.gz'
        with tarfile.open(archive,'r:gz') as stream:
            for name,value in self.data.items():
                self.assertEqual(stream.extractfile('image.sparsebundle/'+name).read(),value)
        self.assertFalse(self.image.exists())
        self.assertEqual(archive.stat().st_mode & 0o777,0o600)

    def test_invalid_image_raw_bytes_are_preserved_before_reclamation(self):
        result = self.recover()
        self.assertEqual(result['state'],'creation-retained',result)
        self.assertIsNone(result['raw_recovery_expiry'])
        self.assert_archive();self.assertEqual(self.commands,[])
        self.assertEqual(recovery.inspect_failed_creation(self.provider,self.request)['state'],'creation-retained')
        self.assertEqual(self.recover()['state'],'creation-retained')

    def test_unjournaled_image_identity_can_recover_after_actual_normal_detach(self):
        self.raw.pop('image_identity');self.raw.update(state='creating',operation='create')
        self.write_json(self.base/'journal.json',self.raw);self.attached=True
        self.assertEqual(self.recover()['state'],'creation-retained')
        self.assertEqual(len(self.commands),1);self.assert_archive()

    def test_missing_journal_requires_positive_normal_detach_receipt(self):
        (self.base/'journal.json').unlink();self.attached=True
        self.assertEqual(self.recover()['state'],'creation-retained');self.assert_archive()

    def test_successful_detach_command_still_requires_absent_image(self):
        self.attached=True
        with patch.object(self.provider,'_run',return_value=b''):
            result=self.recover()
        self.assertEqual(result['state'],'creation-blocked')
        self.assertTrue(self.image.exists());self.assertTrue(self.attached)

    def test_outer_extended_attribute_bytes_are_preserved(self):
        value=b'outer metadata\0\xff'
        if sys.platform == 'darwin':
            subprocess.run(['/usr/bin/xattr','-wx','user.richos_fixture',value.hex(),str(self.image/'Info.plist')],check=True)
        else:
            os.setxattr(self.image/'Info.plist','user.richos_fixture',value)
        self.assertEqual(self.recover()['state'],'creation-retained')
        with tarfile.open(self.base/'failed-creation.tar.gz','r:gz') as archive:
            attributes=json.loads(archive.getmember('image.sparsebundle/Info.plist').pax_headers['RICHOS.xattrs'])
        self.assertEqual(base64.b64decode(attributes['user.richos_fixture']),value)
        self.assert_archive()

    def test_unreadable_extended_attributes_refuse_reclamation(self):
        with patch.object(recovery,'_xattrs',side_effect=OSError('attributes unavailable')):
            result=self.recover()
        self.assertEqual(result['state'],'creation-blocked');self.assertTrue(self.image.exists())
        self.assertIn('attributes unavailable',result['last_error'])

    def test_busy_attached_creation_retains_bytes_and_retries(self):
        self.attached=True;self.busy=True
        result=self.recover();self.assertEqual(result['state'],'creation-blocked')
        self.assertTrue(self.image.exists());self.assertIn('busy',result['last_error'])
        self.busy=False
        self.assertEqual(self.recover()['state'],'creation-retained');self.assert_archive()

    def test_same_boot_interrupted_absence_is_not_a_cutoff(self):
        self.raw.update(state='attached_writable');self.write_json(self.base/'journal.json',self.raw)
        result=self.recover();self.assertEqual(result['state'],'creation-blocked')
        self.assertTrue(self.image.exists());self.assertTrue((self.base/'failed-creation.json').exists())
        self.boot=str(uuid.uuid4())
        self.assertEqual(self.recover()['state'],'creation-retained');self.assert_archive()

    def test_new_boot_recovers_uninitialized_private_image(self):
        self.raw.update(state='creating',operation='create');self.write_json(self.base/'journal.json',self.raw)
        self.boot=str(uuid.uuid4())
        self.assertEqual(self.recover(authorization={'kind':'new-boot'})['state'],'creation-retained')
        self.assert_archive()

    def test_speculative_new_boot_refusal_never_publishes_cancellation(self):
        for mode in ('same','missing','malformed','reader-failure'):
            with self.subTest(mode=mode):
                self.raw['boot_id']=None if mode=='missing' else 'bad' if mode=='malformed' else self.boot
                self.write_json(self.base/'journal.json',self.raw)
                with patch.object(self.provider,'_boot_id',side_effect=RuntimeError('unknown')) if mode=='reader-failure' else patch.object(self.provider,'_boot_id',return_value=self.boot):
                    self.assertEqual(self.recover(authorization={'kind':'new-boot'})['state'],'creation-blocked')
                self.assertFalse((self.base/'failed-creation.json').exists());self.assertTrue(self.image.exists())

    def test_initialized_or_published_workspace_refused_without_cancellation(self):
        self.raw['initialized']=True;self.write_json(self.base/'journal.json',self.raw)
        with self.assertRaisesRegex(recovery.RecoveryError,'initialized'):
            self.recover()
        self.raw.pop('initialized');self.write_json(self.base/'journal.json',self.raw)
        self.write_json(self.base/'lifecycle.json',{'state':'active'})
        with self.assertRaisesRegex(recovery.RecoveryError,'published'):
            self.recover()
        self.assertFalse((self.base/'failed-creation.json').exists());self.assertTrue(self.image.exists())

    def test_forged_request_or_wrong_session_cannot_authorize_recovery(self):
        with self.assertRaises(recovery.RecoveryError):
            self.recover(authorization={'kind':'owner-cancel','session_id':'other'})
        self.request['id']=str(uuid.uuid4())
        with self.assertRaises(recovery.RecoveryError):
            self.recover()
        self.assertTrue(self.image.exists());self.assertFalse((self.base/'failed-creation.json').exists())

    def test_attachment_reader_failure_never_means_absent(self):
        with patch.object(self.provider,'_attached',side_effect=RuntimeError('inventory unavailable')):
            result=self.recover()
        self.assertEqual(result['state'],'creation-blocked');self.assertTrue(self.image.exists())

    def crash_after(self, phase):
        original=recovery._save
        def save(provider,path,state):
            original(provider,path,state)
            if state['phase']==phase:
                raise KeyboardInterrupt('simulated process interruption')
        return patch.object(recovery,'_save',side_effect=save)

    def test_crash_after_capture_then_retry_promotes_exact_archive(self):
        with self.crash_after('captured'),self.assertRaises(KeyboardInterrupt):
            self.recover()
        self.assertTrue(self.image.exists())
        self.assertEqual(self.recover()['state'],'creation-retained');self.assert_archive()

    def test_incomplete_capture_never_authorizes_reclamation(self):
        def incomplete(image,candidate,manifest):
            with tarfile.open(candidate,'w:gz'):
                pass
            candidate.chmod(0o600)
        with patch.object(recovery,'_capture',side_effect=incomplete):
            result=self.recover()
        self.assertEqual(result['state'],'creation-blocked')
        self.assertTrue(self.image.exists())
        self.assertEqual((self.image/'bands/0').read_bytes(),self.data['bands/0'])

    def test_corrupt_candidate_or_changed_source_refuses_reclaim(self):
        with self.crash_after('captured'),self.assertRaises(KeyboardInterrupt):
            self.recover()
        candidate=self.base/'failed-creation.partial.tar.gz';original=candidate.read_bytes()
        candidate.write_bytes(b'corrupt')
        self.assertEqual(self.recover()['state'],'creation-blocked');self.assertTrue(self.image.exists())
        candidate.write_bytes(original)
        (self.image/'bands/0').write_bytes(b'new bytes after prior capture')
        self.assertEqual(self.recover()['state'],'creation-blocked');self.assertTrue(self.image.exists())

    def test_interrupted_partial_reclamation_resumes_from_verified_archive(self):
        original=shutil.rmtree
        def interrupted(path):
            self.assertEqual(path,self.image)
            (self.image/'bands/0').unlink()
            raise KeyboardInterrupt('reclamation interrupted')
        with patch.object(recovery.shutil,'rmtree',side_effect=interrupted),self.assertRaises(KeyboardInterrupt):
            self.recover()
        self.assertFalse((self.image/'bands/0').exists())
        self.assertEqual(self.recover()['state'],'creation-retained');self.assert_archive()

    def test_replaced_image_or_archive_is_retained(self):
        with self.crash_after('reclaiming'),self.assertRaises(KeyboardInterrupt):
            self.recover()
        prior=self.image.with_name('preserved-image');self.image.rename(prior);self.image.mkdir(mode=0o700)
        (self.image/'unique').write_bytes(b'new owner bytes')
        self.assertEqual(self.recover()['state'],'creation-blocked')
        self.assertEqual((self.image/'unique').read_bytes(),b'new owner bytes')
        shutil.rmtree(self.image);prior.rename(self.image)
        (self.base/'failed-creation.tar.gz').write_bytes(b'corrupt')
        self.assertEqual(self.recover()['state'],'creation-blocked');self.assertTrue(self.image.exists())

    def test_symlinks_and_hardlinks_are_not_followed_into_external_data(self):
        external=self.root/'outside';external.write_bytes(b'outside original')
        linked=self.image/'link';linked.symlink_to(external)
        self.assertEqual(self.recover()['state'],'creation-blocked')
        linked.unlink();os.link(external,linked)
        self.assertEqual(self.recover()['state'],'creation-blocked')
        self.assertEqual(external.read_bytes(),b'outside original');self.assertTrue(self.image.exists())

    def test_cancelled_request_before_provider_reservation_gets_atomic_empty_receipt(self):
        shutil.rmtree(self.base)
        result=self.recover();self.assertEqual(result['state'],'creation-empty',result)
        self.assertIsNone(result['raw_recovery_archive']);self.assertTrue(self.base.is_dir())
        self.assertEqual(self.recover()['state'],'creation-empty')
        self.assertEqual(recovery.inspect_failed_creation(self.provider,self.request)['state'],'creation-empty')
        self.assertEqual(self.commands,[])

    def test_unreserved_new_boot_check_is_nonmutating(self):
        shutil.rmtree(self.base)
        self.assertEqual(self.recover(authorization={'kind':'new-boot'})['state'],'creation-blocked')
        self.assertFalse(self.base.exists())

    def test_empty_reservation_publication_never_replaces_concurrent_asset(self):
        shutil.rmtree(self.base)
        original=recovery._publish_empty_directory
        def collision(provider,source,destination):
            destination.mkdir(mode=0o700)
            (destination/'unique').write_bytes(b'other reservation')
            return original(provider,source,destination)
        with patch.object(recovery,'_publish_empty_directory',side_effect=collision):
            result=self.recover()
        self.assertEqual(result['state'],'creation-blocked')
        self.assertEqual((self.base/'unique').read_bytes(),b'other reservation')
        self.assertFalse((self.base/'failed-creation.json').exists())

    def test_verified_empty_reservation_does_not_claim_bytes_reclaimed(self):
        shutil.rmtree(self.image)
        result=self.recover();self.assertEqual(result['state'],'creation-empty')
        self.assertIsNone(result['raw_recovery_archive']);self.assertFalse((self.base/'failed-creation.tar.gz').exists())

    def test_missing_boot_and_missing_image_do_not_infer_safe_empty(self):
        shutil.rmtree(self.image);(self.base/'journal.json').unlink()
        self.assertEqual(self.recover()['state'],'creation-blocked')
        self.assertFalse((self.base/'failed-creation.tar.gz').exists())

    def test_failed_detach_receipt_cannot_be_inferred_on_retry(self):
        self.attached=True
        with self.crash_after('detaching'),self.assertRaises(KeyboardInterrupt):
            self.recover()
        self.attached=False
        self.assertEqual(self.recover()['state'],'creation-blocked');self.assertTrue(self.image.exists())


if __name__=='__main__':
    unittest.main(verbosity=2)
