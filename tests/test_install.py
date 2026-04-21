import os
import pathlib
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "install.sh"


class InstallScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.tmpdir.name)
        self.bin_dir = self.home / "bin"
        self.bin_dir.mkdir(parents=True)

        self._write_executable(
            self.bin_dir / "mvn",
            "#!/usr/bin/env bash\n"
            "if [[ \"$*\" == *settings.localRepository* ]]; then\n"
            "  exit 0\n"
            "fi\n"
            "exit 0\n",
        )

        jdtls = self.home / ".local/share/opencode/bin/jdtls/bin/jdtls"
        jdtls.parent.mkdir(parents=True)
        self._write_executable(jdtls, "#!/usr/bin/env bash\nexit 0\n")

        lombok = self.home / ".m2/repository/org/projectlombok/lombok/1.18.34/lombok-1.18.34.jar"
        lombok.parent.mkdir(parents=True)
        lombok.write_text("fake jar", encoding="utf-8")

        self.config_dir = self.home / ".config/opencode"
        self.config_dir.mkdir(parents=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_direct_interactive_install_writes_config(self):
        proc = PtyProcess(
            f'bash "{SCRIPT}"',
            env=self._env(),
        )
        output, returncode = proc.run(expect="确认应用?", send="y\n")

        self.assertEqual(returncode, 0, msg=output)
        self.assertIn("配置已写入", output)
        self.assert_config_contains_javaagent()

    def test_pipe_interactive_install_writes_config(self):
        proc = PtyProcess(
            f'cat "{SCRIPT}" | bash',
            env=self._env(),
        )
        output, returncode = proc.run(expect="确认应用?", send="y\n")

        self.assertEqual(returncode, 0, msg=output)
        self.assertIn("配置已写入", output)
        self.assert_config_contains_javaagent()

    def test_pipe_yes_install_writes_config(self):
        output = subprocess.run(
            ["bash", "-c", f'cat "{SCRIPT}" | bash -s -- --yes'],
            cwd=REPO_ROOT,
            env=self._env(),
            text=True,
            capture_output=True,
            timeout=30,
        )

        combined = output.stdout + output.stderr
        self.assertEqual(output.returncode, 0, msg=combined)
        self.assertIn("配置已写入", combined)
        self.assert_config_contains_javaagent()

    def assert_config_contains_javaagent(self):
        config = (self.config_dir / "opencode.json").read_text(encoding="utf-8")
        self.assertIn("--jvm-arg=-javaagent:", config)
        self.assertIn("lombok-1.18.34.jar", config)

    def _env(self):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        env["PATH"] = f'{self.bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin'
        env.pop("OPENCODE_JDTLS_LOMBOK_REEXEC", None)
        return env

    @staticmethod
    def _write_executable(path: pathlib.Path, content: str):
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)


class PtyProcess:
    def __init__(self, command: str, env):
        self.command = command
        self.env = env

    def run(self, expect: str, send: str, timeout: float = 30.0):
        pid, master_fd = pty.fork()
        if pid == 0:
            os.chdir(REPO_ROOT)
            os.execvpe("bash", ["bash", "-c", self.command], self.env)

        chunks = []
        deadline = time.time() + timeout
        sent = False

        try:
            while True:
                if time.time() > deadline:
                    os.kill(pid, signal.SIGKILL)
                    raise AssertionError(self._render(chunks) + "\n<timeout>")

                ready, _, _ = select.select([master_fd], [], [], 0.2)
                if ready:
                    try:
                        data = os.read(master_fd, 4096)
                    except OSError:
                        data = b""
                    if data:
                        chunks.append(data)
                        rendered = self._render(chunks)
                        if not sent and expect in rendered:
                            os.write(master_fd, send.encode("utf-8"))
                            sent = True

                waited_pid, status = os.waitpid(pid, os.WNOHANG)
                if waited_pid != 0:
                    while True:
                        ready, _, _ = select.select([master_fd], [], [], 0)
                        if not ready:
                            break
                        try:
                            data = os.read(master_fd, 4096)
                        except OSError:
                            break
                        if not data:
                            break
                        chunks.append(data)
                    return self._render(chunks), os.waitstatus_to_exitcode(status)
        finally:
            os.close(master_fd)
            try:
                waited_pid, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                waited_pid = pid
            if waited_pid == 0:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)

    @staticmethod
    def _render(chunks):
        return b"".join(chunks).decode("utf-8", errors="replace")


if __name__ == "__main__":
    unittest.main()
