#!/usr/bin/env python3
"""Unprivileged, synthetic-only tests; run directly with Python's unittest."""

import base64
import contextlib
import fcntl
import hashlib
import io
import os
import pty
import runpy
import secrets
import select
import signal
import stat
import string
import subprocess
import sys
import tempfile
import termios
import time
import types
import unittest
import warnings
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True

HELPER = Path(__file__).resolve().parents[2] / "deploy/iex-code-owner-auth-provision"


def random_ascii(length):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(length))


def synthetic_hash():
    salt = base64.b64encode(b"\xff" + secrets.token_bytes(15)).decode("ascii")
    digest = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    return "pbkdf2_sha256$600000$" + salt + "$" + digest


class HelperTestCase(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), "The provisioning helper must exist.")
        self.helper = types.SimpleNamespace(**runpy.run_path(str(HELPER)))
        self.username = "owner-" + secrets.token_hex(8)
        self.password = secrets.token_urlsafe(24)

    def assert_rejected(self, function, *args, **kwargs):
        with self.assertRaises(self.helper.ProvisioningError) as raised:
            function(*args, **kwargs)
        self.assertEqual(
            str(raised.exception),
            "Owner authentication provisioning failed.",
            "Validation errors must not contain input values.",
        )


class CredentialValidationTests(HelperTestCase):
    def test_username_allows_only_bounded_case_sensitive_ascii(self):
        allowed = random_ascii(57) + "_.@-012"
        self.assertTrue(self.helper.validate_username(allowed) == allowed)
        self.assertTrue(self.helper.validate_username(random_ascii(1)))
        self.assertTrue(self.helper.validate_username(random_ascii(64)))

        for value in (
            "",
            random_ascii(65),
            self.username + " ",
            self.username + "\n",
            self.username + "\x00",
            self.username + "'",
            self.username + "$",
            self.username + chr(0x100 + secrets.randbelow(64)),
            None,
        ):
            self.assert_rejected(self.helper.validate_username, value)

    def test_password_bounds_count_characters_and_utf8_bytes_without_normalization(self):
        for value in (random_ascii(15), random_ascii(1024), " " + self.password + " "):
            self.assertTrue(self.helper.validate_password(value) == value.encode("utf-8"))

        unicode_password = "".join(chr(0x800 + secrets.randbelow(64)) for _ in range(341))
        self.assertTrue(
            len(self.helper.validate_password(unicode_password + random_ascii(1))) == 1024
        )
        for value in (
            random_ascii(14),
            random_ascii(1025),
            unicode_password + random_ascii(2),
            self.password + chr(0xD800 + secrets.randbelow(0x800)),
            None,
            secrets.token_bytes(24),
        ):
            self.assert_rejected(self.helper.validate_password, value)

    def test_derivation_matches_independent_stdlib_reference_and_exact_encoding(self):
        encoded = self.helper.derive_password_hash(self.password)
        self.assertTrue(len(encoded) == 90)
        algorithm, iterations, salt_text, digest_text = encoded.split("$")
        self.assertEqual(algorithm, "pbkdf2_sha256")
        self.assertEqual(iterations, "600000")
        self.assertTrue(len(salt_text) == 24 and salt_text.endswith("=="))
        self.assertTrue(len(digest_text) == 44 and digest_text.endswith("="))
        salt = base64.b64decode(salt_text, validate=True)
        digest = base64.b64decode(digest_text, validate=True)
        self.assertTrue(len(salt) == 16 and len(digest) == 32)
        self.assertTrue(salt_text == base64.b64encode(salt).decode("ascii"))
        self.assertTrue(digest_text == base64.b64encode(digest).decode("ascii"))
        expected = hashlib.pbkdf2_hmac("sha256", self.password.encode("utf-8"), salt, 600000, 32)
        self.assertTrue(secrets.compare_digest(digest, expected), "The KDF must match.")
        self.assertTrue(self.helper.validate_password_hash(encoded) == encoded)
        self.assertFalse(
            encoded == self.helper.derive_password_hash(self.password),
            "Each derivation must have a fresh random salt.",
        )

    def test_hash_validation_rejects_noncanonical_or_unsupported_encodings(self):
        encoded = synthetic_hash()
        algorithm, iterations, salt, digest = encoded.split("$")
        self.assertTrue(self.helper.validate_password_hash(encoded) == encoded)
        for value in (
            encoded.replace(algorithm, "pbkdf2_sha512", 1),
            encoded.replace(iterations, "060000", 1),
            encoded.replace(iterations, "599999", 1),
            encoded + "$",
            encoded + "\n",
            encoded.replace(salt, salt.rstrip("="), 1),
            encoded.replace(digest, digest.rstrip("="), 1),
            encoded.replace(salt, salt.replace("/", "_"), 1),
            encoded.replace(salt, base64.b64encode(secrets.token_bytes(15)).decode("ascii"), 1),
            encoded.replace(digest, base64.b64encode(secrets.token_bytes(31)).decode("ascii"), 1),
            " " + encoded,
            None,
            encoded.encode("ascii"),
        ):
            self.assert_rejected(self.helper.validate_password_hash, value)


class EnvFileWriteTests(HelperTestCase):
    def test_private_metadata_requires_exact_owner_and_private_regular_file(self):
        self.assertTrue(hasattr(self.helper, "validate_private_directory"))
        self.assertTrue(hasattr(self.helper, "validate_private_file"))
        directory = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o700)
        file_info = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o600, st_nlink=1)
        self.helper.validate_private_directory(directory)
        self.helper.validate_private_file(file_info)
        for info in (
            types.SimpleNamespace(st_uid=100_001, st_mode=stat.S_IFDIR | 0o700),
            types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o750),
            types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFLNK | 0o700),
        ):
            self.assert_rejected(self.helper.validate_private_directory, info)
        for info in (
            types.SimpleNamespace(st_uid=100_001, st_mode=stat.S_IFREG | 0o600, st_nlink=1),
            types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o640, st_nlink=1),
            types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o600, st_nlink=2),
            types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFLNK | 0o600, st_nlink=1),
        ):
            self.assert_rejected(self.helper.validate_private_file, info)

    def make_env_file(self, contents):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name).resolve() / "app.env"
        path.write_bytes(contents)
        os.chmod(path, 0o600)
        return path

    def test_replaces_both_auth_entries_atomically_and_preserves_other_bytes(self):
        old_username = ("old-" + secrets.token_hex(8)).encode("ascii")
        old_hash = synthetic_hash().encode("ascii")
        original = (
            b"# preserve this comment \xff\n"
            b"OTHER=unrelated$bytes\n"
            b"IEX_CODE_AUTH_USERNAME='" + old_username + b"'\r\n"
            b"MIDDLE=keep\n"
            b"IEX_CODE_AUTH_PASSWORD_HASH='" + old_hash + b"'\n"
            b"TRAILING=without-newline"
        )
        path = self.make_env_file(original)
        old_inode = path.stat().st_ino
        password_hash = synthetic_hash()

        self.helper.write_env_file(str(path), self.username, password_hash, require_root=False)

        rendered = path.read_bytes()
        self.assertNotEqual(path.stat().st_ino, old_inode)
        self.assertTrue(stat.S_ISREG(path.stat().st_mode))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertTrue(b"# preserve this comment \xff\n" in rendered)
        self.assertTrue(b"OTHER=unrelated$bytes\n" in rendered)
        self.assertTrue(
            ("IEX_CODE_AUTH_USERNAME='" + self.username + "'\r\n").encode("ascii") in rendered
        )
        self.assertTrue(
            ("IEX_CODE_AUTH_PASSWORD_HASH='" + password_hash + "'\n").encode("ascii") in rendered
        )
        self.assertTrue(b"TRAILING=without-newline" in rendered)
        self.assertTrue(old_username not in rendered)
        self.assertTrue(old_hash not in rendered)

    def test_appends_missing_auth_entries_without_rewriting_unrelated_no_newline_bytes(self):
        self.assertEqual(self.helper.USERNAME_KEY, "IEX_CODE_AUTH_USERNAME")
        self.assertEqual(self.helper.PASSWORD_HASH_KEY, "IEX_CODE_AUTH_PASSWORD_HASH")
        original = b"OTHER=keep"
        path = self.make_env_file(original)

        self.helper.write_env_file(path, self.username, synthetic_hash(), require_root=False)

        rendered = path.read_bytes()
        self.assertTrue(rendered.startswith(original + b"\n"))
        self.assertTrue(
            ("IEX_CODE_AUTH_USERNAME='" + self.username + "'\n").encode("ascii") in rendered
        )
        self.assertEqual(rendered.count(b"IEX_CODE_AUTH_USERNAME="), 1)
        self.assertEqual(rendered.count(b"IEX_CODE_AUTH_PASSWORD_HASH="), 1)

    def test_rejects_duplicate_or_multiline_auth_entries_without_changing_file(self):
        fixtures = (
            b"IEX_CODE_AUTH_USERNAME=first\nIEX_CODE_AUTH_USERNAME=second\n",
            b"IEX_CODE_AUTH_PASSWORD_HASH='unterminated\nnext line'\n",
            b"IEX_CODE_AUTH_USERNAME='unterminated\nOTHER=value\n",
            b"IEX_CODE_AUTH_PASSWORD_HASH\n",
            b"IEX_CODE_AUTH_USERNAME=x\n export IEX_CODE_AUTH_USERNAME = y\n",
        )
        for original in fixtures:
            path = self.make_env_file(original)
            self.assert_rejected(
                self.helper.write_env_file,
                path,
                self.username,
                synthetic_hash(),
                require_root=False,
            )
            self.assertEqual(path.read_bytes(), original)

    def test_rejects_ambiguous_auth_syntax_without_changing_file(self):
        for original in (
            b"IEX_CODE_AUTH_USERNAME: value\n",
            b"IEX_CODE_AUTH_USERNAME='old' trailing\n",
            b"IEX_CODE_AUTH_USERNAME=value\\\ncontinued\n",
            b"\xef\xbb\xbfIEX_CODE_AUTH_USERNAME=value\n",
            b"IEX_CODE_AUTH_USERNAME=value\x00hidden\n",
            b"OTHER='unterminated\nIEX_CODE_AUTH_USERNAME=value\n",
        ):
            path = self.make_env_file(original)
            self.assert_rejected(
                self.helper.write_env_file, path, self.username, synthetic_hash(), require_root=False
            )
            self.assertTrue(path.read_bytes() == original)

    def test_preserves_unrelated_multiline_strings_and_exact_no_newline_tail(self):
        original = (
            b"OTHER='one\nIEX_CODE_AUTH_USERNAME=literal\nthree'\n"
            b" export IEX_CODE_AUTH_USERNAME = 'old' # owner's comment\n"
            b"IEX_CODE_AUTH_PASSWORD_HASH=old\n"
            b"TAIL=no-final-newline"
        )
        path = self.make_env_file(original)
        self.helper.write_env_file(path, self.username, synthetic_hash(), require_root=False)
        rendered = path.read_bytes()
        self.assertTrue(rendered.startswith(b"OTHER='one\nIEX_CODE_AUTH_USERNAME=literal\nthree'\n"))
        self.assertTrue(rendered.endswith(b"TAIL=no-final-newline"))

    def test_rejects_symlink_and_nonprivate_targets(self):
        path = self.make_env_file(b"OTHER=keep\n")
        symlink = path.parent / "linked.env"
        symlink.symlink_to(path)
        self.assert_rejected(
            self.helper.write_env_file,
            symlink,
            self.username,
            synthetic_hash(),
            require_root=False,
        )
        os.chmod(path, 0o640)
        self.assert_rejected(
            self.helper.write_env_file,
            path,
            self.username,
            synthetic_hash(),
            require_root=False,
        )
        os.chmod(path, 0o600)
        os.chmod(path.parent, 0o750)
        self.assert_rejected(
            self.helper.write_env_file,
            path,
            self.username,
            synthetic_hash(),
            require_root=False,
        )

    def test_rejects_symlink_ancestors_hardlinks_and_nonregular_files(self):
        path = self.make_env_file(b"OTHER=keep\n")
        os.link(path, path.parent / "second.env")
        self.assert_rejected(
            self.helper.write_env_file, path, self.username, synthetic_hash(), require_root=False
        )
        fifo = path.parent / "fifo"
        os.mkfifo(fifo, 0o600)
        for target in (fifo, path.parent, path.parent / "missing.env"):
            self.assert_rejected(
                self.helper.write_env_file, target, self.username, synthetic_hash(), require_root=False
            )
        nested = path.parent / "nested"
        inner = nested / "inner"
        inner.mkdir(parents=True, mode=0o700)
        os.chmod(nested, 0o700)
        target = inner / "app.env"
        target.write_bytes(b"OTHER=keep\n")
        os.chmod(target, 0o600)
        alias = path.parent / "alias"
        alias.symlink_to(nested, target_is_directory=True)
        self.assert_rejected(
            self.helper.write_env_file,
            alias / "inner/app.env",
            self.username,
            synthetic_hash(),
            require_root=False,
        )

    def test_rejects_special_or_executable_modes_and_unprivileged_default_write(self):
        for mode in (0o610, 0o700, 0o4600):
            path = self.make_env_file(b"OTHER=keep\n")
            os.chmod(path, mode)
            self.assert_rejected(
                self.helper.write_env_file, path, self.username, synthetic_hash(), require_root=False
            )
        path = self.make_env_file(b"OTHER=keep\n")
        with mock.patch.object(self.helper.os, "geteuid", return_value=100_001):
            self.assert_rejected(self.helper.write_env_file, path, self.username, synthetic_hash())

    def test_private_temp_is_fsynced_before_pinned_directory_atomic_replace(self):
        path = self.make_env_file(b"OTHER=keep\n")
        original_info = path.stat()
        events = []
        real_fsync, real_replace, real_open = os.fsync, os.replace, os.open

        def open_file(name, flags, *args, **kwargs):
            if flags & os.O_CREAT:
                self.assertTrue(flags & os.O_EXCL)
                self.assertTrue(flags & os.O_NOFOLLOW)
            return real_open(name, flags, *args, **kwargs)

        def fsync(fd):
            info = os.fstat(fd)
            if stat.S_ISREG(info.st_mode):
                self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
                self.assertEqual(
                    (info.st_uid, info.st_gid), (original_info.st_uid, original_info.st_gid)
                )
                events.append("file")
            else:
                events.append("directory")
            return real_fsync(fd)

        def replace(source, destination, **kwargs):
            self.assertEqual(events, ["file"])
            self.assertTrue(
                "src_dir_fd" in kwargs and kwargs["src_dir_fd"] == kwargs.get("dst_dir_fd"),
                "Rename must use the same pinned directory.",
            )
            self.assertEqual(os.fstat(kwargs["src_dir_fd"]).st_ino, path.parent.stat().st_ino)
            events.append("replace")
            return real_replace(source, destination, **kwargs)

        with (
            mock.patch.object(self.helper.os, "open", side_effect=open_file),
            mock.patch.object(self.helper.os, "fsync", side_effect=fsync),
            mock.patch.object(self.helper.os, "replace", side_effect=replace),
        ):
            self.helper.write_env_file(path, self.username, synthetic_hash(), require_root=False)
        self.assertEqual(events, ["file", "replace", "directory"])
        self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_failed_writes_clean_temp_without_output_or_exception_secret_values(self):
        for operation in ("fsync", "replace"):
            path = self.make_env_file(b"OTHER=keep\n")
            stdout, stderr = io.StringIO(), io.StringIO()
            with (
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
                mock.patch.object(self.helper.os, operation, side_effect=OSError(self.password)),
            ):
                self.assert_rejected(
                    self.helper.write_env_file,
                    path,
                    self.username,
                    synthetic_hash(),
                    require_root=False,
                )
            self.assertTrue(path.read_bytes() == b"OTHER=keep\n")
            self.assertEqual(len(list(path.parent.iterdir())), 1)
            self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")

    def test_short_reads_preserve_unrelated_bytes(self):
        original = b"OTHER=" + secrets.token_bytes(128).hex().encode("ascii") + b"\n"
        path = self.make_env_file(original)
        real_read = os.read
        with mock.patch.object(self.helper.os, "read", side_effect=lambda fd, size: real_read(fd, 7)):
            self.helper.write_env_file(path, self.username, synthetic_hash(), require_root=False)
        self.assertTrue(path.read_bytes().startswith(original))

    def test_changed_target_is_not_clobbered_after_temp_fsync(self):
        path = self.make_env_file(b"OTHER=before\n")
        real_fsync = os.fsync

        def fsync(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode):
                path.write_bytes(b"OTHER=concurrent-change\n")
            return real_fsync(fd)

        with mock.patch.object(self.helper.os, "fsync", side_effect=fsync):
            self.assert_rejected(
                self.helper.write_env_file, path, self.username, synthetic_hash(), require_root=False
            )
        self.assertTrue(path.read_bytes() == b"OTHER=concurrent-change\n")
        self.assertEqual(len(list(path.parent.iterdir())), 1)


class CommandLineTests(HelperTestCase):
    def test_rejects_commandline_credentials_without_echoing_them(self):
        result = subprocess.run(
            [sys.executable, "-B", str(HELPER), "/nonexistent/app.env", self.username, self.password],
            input="",
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Owner authentication provisioning failed.\n")


class TtyStream(io.StringIO):
    def isatty(self):
        return True


class InteractiveCredentialTests(HelperTestCase):
    def tty_reader(self):
        master, slave = pty.openpty()
        completed_read, completed_write = os.pipe()
        child_code = (
            "import os, runpy, sys, termios\n"
            f"helper = runpy.run_path({str(HELPER)!r})\n"
            "status = 0\n"
            "try:\n"
            "    helper['read_credentials']()\n"
            "except BaseException:\n"
            "    status = 1\n"
            "echo = bool(termios.tcgetattr(0)[3] & termios.ECHO)\n"
            f"os.write({completed_write}, bytes((status, echo)))\n"
            # The parent checks terminal restoration before exit. Avoid
            # interpreter-level TTY draining during this synthetic harness.
            "os._exit(status)\n"
        )

        def attach_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        child = subprocess.Popen(
            [sys.executable, "-B", "-c", child_code],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            pass_fds=(completed_write,),
            preexec_fn=attach_tty,
        )
        os.close(completed_write)

        def cleanup():
            if child.poll() is None:
                child.kill()
            os.close(master)
            os.close(slave)
            os.close(completed_read)
            child.wait(timeout=5)

        self.addCleanup(cleanup)
        return child, master, slave, completed_read, bytearray()

    def wait_for_prompt(self, master, output, prompt):
        deadline = time.monotonic() + 5
        while prompt not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
            if ready:
                try:
                    output.extend(os.read(master, 4096))
                except OSError:
                    break
        self.assertTrue(prompt in output, "Expected hidden-input prompt did not appear.")

    def send_hidden_line(self, slave, master, value):
        self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO, "Echo must be disabled.")
        os.write(master, value.encode("utf-8") + b"\n")

    def assert_tty_result(self, child, completed, expected_status):
        ready, _, _ = select.select([completed], [], [], 5)
        self.assertTrue(ready, "The credential reader must finish.")
        self.assertEqual(os.read(completed, 2), bytes((expected_status, 1)))

    def test_real_tty_hides_all_credentials_and_restores_echo_after_success(self):
        child, master, slave, completed, output = self.tty_reader()
        password = chr(0x800 + secrets.randbelow(64)) + self.password
        for prompt, value in (
            (b"Owner username: ", self.username),
            (b"Owner password: ", password),
            (b"Confirm password: ", password),
        ):
            self.wait_for_prompt(master, output, prompt)
            self.send_hidden_line(slave, master, value)
        self.assert_tty_result(child, completed, 0)
        self.assertFalse(self.username.encode("ascii") in output)
        self.assertFalse(password.encode("utf-8") in output)

    def test_real_tty_signals_and_eof_restore_echo_before_failure(self):
        for signum in (
            signal.SIGINT,
            signal.SIGTERM,
            signal.SIGHUP,
            signal.SIGQUIT,
            signal.SIGTSTP,
            None,
        ):
            child, master, slave, completed, output = self.tty_reader()
            self.wait_for_prompt(master, output, b"Owner username: ")
            self.send_hidden_line(slave, master, self.username)
            self.wait_for_prompt(master, output, b"Owner password: ")
            self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
            if signum is None:
                os.write(master, b"\x04")
            else:
                os.kill(child.pid, signum)
            self.assert_tty_result(child, completed, 1)

    def test_reader_requires_tty_and_rejects_mismatch_without_echoing_values(self):
        self.assertTrue(hasattr(self.helper, "read_credentials"))
        with mock.patch.object(self.helper.sys, "stdin", io.StringIO()):
            self.assert_rejected(self.helper.read_credentials)

        stderr = TtyStream()
        with (
            contextlib.redirect_stderr(stderr),
            mock.patch.object(self.helper.sys, "stdin", TtyStream(self.username + "\n")),
            mock.patch.object(self.helper.sys, "stderr", stderr),
            mock.patch.object(
                self.helper.getpass,
                "getpass",
                side_effect=[self.username, self.password, secrets.token_urlsafe(24)],
            ),
        ):
            self.assert_rejected(self.helper.read_credentials)
        self.assertFalse(self.password in stderr.getvalue())

    def test_getpass_echo_fallback_is_rejected_without_warning_output(self):
        stderr = TtyStream()

        def unsafe_getpass(*args, **kwargs):
            warnings.warn("Echo unavailable.", self.helper.getpass.GetPassWarning)
            return self.password

        with (
            contextlib.redirect_stderr(stderr),
            mock.patch.object(self.helper.sys, "stdin", TtyStream(self.username + "\n")),
            mock.patch.object(self.helper.sys, "stderr", stderr),
            mock.patch.object(self.helper.getpass, "getpass", side_effect=unsafe_getpass),
        ):
            self.assert_rejected(self.helper.read_credentials)
        self.assertFalse("Echo unavailable." in stderr.getvalue())
        self.assertFalse(self.password in stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
