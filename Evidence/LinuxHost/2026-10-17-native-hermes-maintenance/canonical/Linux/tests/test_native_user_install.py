"""Existing user-private group directories must not require global chmod."""
import grp
import errno
import os
from pathlib import Path
import pwd
import sys
import struct
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'packaging'))
from native_user_install import UserIntegration, private_user_group, no_extended_acl


class PrivateGroupTests(unittest.TestCase):
    def account(self, name='alice', uid=1000, gid=1000):
        return pwd.struct_passwd((name,'x',uid,gid,'','/home/'+name,'/bin/sh'))

    def check_group(self, members=(), accounts=None, group_name='alice', gid=1000):
        user=self.account()
        with patch('native_user_install.pwd.getpwuid',return_value=user), \
             patch('native_user_install.grp.getgrgid',return_value=grp.struct_group((group_name,'x',gid,list(members)))), \
             patch('native_user_install.pwd.getpwall',return_value=accounts or [user]):
            return private_user_group(user.pw_uid,gid)

    def test_private_primary_group(self):
        self.assertTrue(self.check_group())
        self.assertTrue(self.check_group(members=['alice']))

    def test_supplementary_other_member_refused(self):
        self.assertFalse(self.check_group(members=['bob']))

    def test_other_primary_member_refused(self):
        self.assertFalse(self.check_group(accounts=[self.account(),self.account('bob',1001,1000)]))

    def test_shared_or_nonprimary_group_refused(self):
        self.assertFalse(self.check_group(group_name='users'))
        self.assertFalse(self.check_group(gid=1001))

    def test_unknown_group_refused(self):
        with patch('native_user_install.pwd.getpwuid',side_effect=KeyError):
            self.assertFalse(private_user_group(1000,1000))

    def test_acl_absence_and_read_failure(self):
        with patch('native_user_install.os.getxattr',side_effect=OSError(errno.ENODATA,'No ACL')):
            self.assertTrue(no_extended_acl('/unused'))
        with patch('native_user_install.os.getxattr',side_effect=PermissionError(errno.EACCES,'Denied')):
            self.assertFalse(no_extended_acl('/unused'))
        with patch('native_user_install.os.getxattr',return_value=b'extended ACL'):
            self.assertFalse(no_extended_acl('/unused'))

    def test_real_acl_cannot_use_private_group_exception(self):
        if os.geteuid()==0:self.skipTest('User integration runs as a non-root desktop user')
        user=object.__new__(UserIntegration);user.uid=os.geteuid();user.private_gid=os.getegid()
        parent=Path(__file__).resolve().parents[2]/'Build/Linux'
        with tempfile.TemporaryDirectory(prefix='user-acl-test.',dir=parent) as temp:
            directory=Path(temp)/'icons';directory.mkdir();directory.chmod(0o775)
            entries=[(1,7,0xffffffff),(2,7,user.uid+10000),(4,7,0xffffffff),
                     (16,7,0xffffffff),(32,5,0xffffffff)]
            acl=struct.pack('<I',2)+b''.join(struct.pack('<HHI',*entry) for entry in entries)
            for attribute in ('system.posix_acl_access','system.posix_acl_default'):
                os.setxattr(directory,attribute,acl)
                with self.assertRaisesRegex(ValueError,'Untrusted user integration path'):
                    user.check(directory,directory=True)
                os.removexattr(directory,attribute)
            user.check(directory,directory=True)

    def test_actual_directory_modes_and_symlink(self):
        # Exercise the path validator on real private files, without invoking
        # installation, touching the system home or changing any ancestor.
        if os.geteuid()==0:self.skipTest('User integration runs as a non-root desktop user')
        user=object.__new__(UserIntegration)
        user.uid=os.geteuid();user.private_gid=os.getegid()
        parent=Path(__file__).resolve().parents[2]/'Build/Linux'
        with tempfile.TemporaryDirectory(prefix='user-path-test.',dir=parent) as temp:
            root=Path(temp);directory=root/'icons';directory.mkdir(mode=0o775);directory.chmod(0o775)
            user.check(directory,directory=True)
            self.assertEqual(directory.stat().st_mode&0o777,0o775)
            user.private_gid=None
            with self.assertRaisesRegex(ValueError,'Untrusted user integration path'):
                user.check(directory,directory=True)
            user.private_gid=os.getegid();directory.chmod(0o777)
            with self.assertRaisesRegex(ValueError,'Untrusted user integration path'):
                user.check(directory,directory=True)
            directory.chmod(0o775);alias=root/'alias';alias.symlink_to(directory)
            with self.assertRaisesRegex(ValueError,'Untrusted user integration path'):
                user.check(alias,directory=True)

    def test_config_permissions_migrate_without_content_changes(self):
        if os.geteuid()==0:self.skipTest('User integration runs as a non-root desktop user')
        user=object.__new__(UserIntegration);user.uid=os.geteuid();user.private_gid=os.getegid()
        parent=Path(__file__).resolve().parents[2]/'Build/Linux'
        with tempfile.TemporaryDirectory(prefix='user-config-test.',dir=parent) as temp:
            user.config=Path(temp)/'config';user.config.mkdir(mode=0o700)
            directory=user.config/'farpane';directory.mkdir();directory.chmod(0o775)
            contents=b'encrypted-identity-and-password-placeholder\n'
            identity=directory/'FarPane.toml';identity.write_bytes(contents)
            user.secure_configuration()
            self.assertEqual(directory.stat().st_mode&0o777,0o700)
            self.assertEqual(identity.read_bytes(),contents)
            self.assertEqual(user.config.stat().st_mode&0o777,0o700)
            user.secure_configuration()
            self.assertEqual(identity.read_bytes(),contents)

    def test_new_configuration_private_and_shared_group_rejected(self):
        if os.geteuid()==0:self.skipTest('User integration runs as a non-root desktop user')
        user=object.__new__(UserIntegration);user.uid=os.geteuid();user.private_gid=os.getegid()
        parent=Path(__file__).resolve().parents[2]/'Build/Linux'
        with tempfile.TemporaryDirectory(prefix='user-config-test.',dir=parent) as temp:
            user.config=Path(temp)/'config';user.state=Path(temp)/'state'
            user.secure_configuration();directory=user.config/'farpane'
            self.assertEqual(directory.stat().st_mode&0o777,0o700)
            self.assertEqual(list(directory.iterdir()),[])
            directory.chmod(0o775);user.private_gid=None
            with self.assertRaisesRegex(ValueError,'Untrusted user integration path'):
                user.secure_configuration()
            self.assertEqual(directory.stat().st_mode&0o777,0o775)


if __name__=='__main__':unittest.main()
