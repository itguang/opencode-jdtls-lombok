# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Installer scripts that inject Lombok `-javaagent` into [opencode](https://opencode.ai)'s built-in jdtls (Java LSP server), eliminating false-positive errors caused by `@Data`, `@Slf4j`, `@RequiredArgsConstructor`, etc. The tool modifies `~/.config/opencode/opencode.json` to override the jdtls launch command.

## Repository Structure

- `install.sh` — Bash installer for macOS / Linux / WSL (interactive + `--yes` mode + `--uninstall`)
- `install.ps1` — PowerShell installer for native Windows (mirrors install.sh behavior)
- `tests/test_install.py` — Integration tests for install.sh using PTY-based interactive simulation
- `tests/test_install_ps1.py` — Structural/smoke tests for install.ps1

Both installers follow the same 5-step flow: detect OS, find jdtls binary, resolve Lombok jar (local Maven repo or download from Central), preview config, backup + merge JSON into opencode.json.

## Running Tests

```bash
# All tests
python3 -m pytest tests/ -v

# Single test file
python3 -m pytest tests/test_install.py -v

# Single test method
python3 -m pytest tests/test_install.py::InstallScriptTest::test_pipe_yes_install_writes_config -v

# With unittest directly
python3 -m unittest tests.test_install -v
```

The install.sh tests use `pty.fork()` to simulate interactive terminal input (typing "y" at confirmation prompts). They create a temporary HOME with fake jdtls binary and Lombok jar, so they run without affecting the real system.

## Key Design Decisions

- JSON merging uses `jq` with `python3` as fallback — both paths must stay functionally equivalent
- Interactive confirmation reads from `/dev/tty` (fd 3) when piped (`curl | bash`), not from stdin
- Config writes always backup first to `opencode.json.bak.<timestamp>`
- Only the `lsp.jdtls` block is modified; all other opencode config keys are preserved
- Lombok jar resolution priority: local Maven repo (highest semver) → Maven Central download to `~/.opencode-jdtls-lombok/`

## Language

User-facing output (banners, prompts, hints, error messages) in both scripts is written in Chinese (简体中文). Maintain this convention when modifying output strings.
