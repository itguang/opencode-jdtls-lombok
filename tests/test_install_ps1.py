import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "install.ps1"
README = REPO_ROOT / "README.md"


class InstallPs1StructureTest(unittest.TestCase):
    def test_script_exists(self):
        self.assertTrue(SCRIPT.exists())

    def test_script_declares_expected_parameters(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("[switch]$Yes", text)
        self.assertIn("[switch]$Uninstall", text)
        self.assertIn("[string]$LombokVersion", text)
        self.assertIn("[switch]$Help", text)

    def test_script_contains_core_functions(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("function Find-OpencodeJdtls", text)
        self.assertIn("function Find-Java21", text)
        self.assertIn("function Resolve-LombokJar", text)
        self.assertIn("function Merge-JdtlsConfig", text)
        self.assertIn("function Remove-JdtlsConfig", text)
        self.assertIn("function Invoke-Install", text)
        self.assertIn("function Invoke-Uninstall", text)

    def test_readme_mentions_windows_installer(self):
        text = README.read_text(encoding="utf-8")
        self.assertIn("install.ps1", text)
        self.assertIn("原生 Windows", text)
        self.assertIn("PowerShell", text)


if __name__ == "__main__":
    unittest.main()
