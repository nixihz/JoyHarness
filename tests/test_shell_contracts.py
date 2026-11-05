"""Static contracts for the repository shell scripts.

Every script runs under `set -euo pipefail`, so expanding a variable that is
never assigned aborts the whole script. ShellCheck does not report unassigned
all-caps names because it assumes they may come from the environment, so the
check lives here.
"""

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = sorted((ROOT / "scripts").glob("*.sh"))

ENVIRONMENT_VARIABLES = {
    "BASH_SOURCE", "DEVELOPER_DIR", "EUID", "HOME", "IFS", "LANG", "LC_ALL",
    "LINENO", "MACHTYPE", "OLDPWD", "OSTYPE", "PATH", "PWD", "RANDOM", "SECONDS",
    "SHELL", "TERM", "TMPDIR", "UID", "USER",
}
POSITION_ARGUMENTS = {
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "@", "*", "#", "?", "!", "-",
}
READ_FLAGS = {"-a", "-d", "-e", "-i", "-n", "-N", "-p", "-r", "-s", "-t", "-u"}
READ_FLAG_ARGUMENTS = {"-d", "-i", "-n", "-p", "-t", "-u"}
# `${name:-fallback}`, `${name:=fallback}`, `${name:+value}` and the pattern
# forms never fail under `set -u`; a bare `${name}` and `${#name}` do.
SAFE_EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[-:=#%+./\[]")
LENGTH_EXPANSION = re.compile(r"\$\{#([A-Za-z_][A-Za-z0-9_]*)\}")
BRACE_EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
BARE_EXPANSION = re.compile(r"(?<![\w$])\$([A-Za-z_][A-Za-z0-9_]*)\b")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGNMENT = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\+?=(?!=)")
DECLARATION = re.compile(
    r"^\s*(?:export\s+|local\s+|readonly\s+|declare\s+(?:-[A-Za-z]+\s+)?)?"
    r"([A-Za-z_][A-Za-z0-9_]*(?:\s+[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:#.*)?$",
    re.M,
)
FOR_VARIABLE = re.compile(r"^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b", re.M)
READ_LINE = re.compile(r"\bread\s+([^;]*)")


def readable_source(script: str) -> str:
    """Drop comments and single-quoted literals that cannot expand a variable."""
    lines = [
        line for line in script.splitlines()
        if not line.strip().startswith("#")
    ]
    source = "\n".join(lines)
    # Single quotes suppress expansion, including the multi-line awk and
    # JavaScript programs the scripts embed.
    return re.sub(r"'[^']*'", "''", source, flags=re.S)


def assigned_variables(source: str) -> set:
    assigned = set(ASSIGNMENT.findall(source))
    for declaration in DECLARATION.findall(source):
        assigned |= set(IDENTIFIER.findall(declaration))
    assigned |= set(FOR_VARIABLE.findall(source))
    for statement in READ_LINE.findall(source):
        skip_next = False
        for token in statement.split():
            if skip_next:
                skip_next = False
                continue
            if token in READ_FLAGS:
                skip_next = token in READ_FLAG_ARGUMENTS
                continue
            if IDENTIFIER.fullmatch(token):
                assigned.add(token)
    return assigned


def undefined_variables(script: str) -> set:
    source = readable_source(script)
    assigned = assigned_variables(source)
    safe = set(SAFE_EXPANSION.findall(source))
    references = set(LENGTH_EXPANSION.findall(source))
    references |= set(BRACE_EXPANSION.findall(source))
    references |= set(BARE_EXPANSION.findall(source))
    return {
        name
        for name in references
        if name not in assigned
        and name not in safe
        and name not in ENVIRONMENT_VARIABLES
        and name not in POSITION_ARGUMENTS
        and not name.startswith("JOY_HARNESS_")
    }


class ShellContractTests(unittest.TestCase):
    def test_shell_scripts_only_expand_defined_variables(self) -> None:
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                self.assertEqual(
                    undefined_variables(script.read_text(encoding="utf-8")),
                    set(),
                    f"{script.name} expands a variable it never assigns",
                )

    def test_shell_scripts_pass_the_bash_syntax_check(self) -> None:
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                result = subprocess.run(
                    ["bash", "-n", str(script)], capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
