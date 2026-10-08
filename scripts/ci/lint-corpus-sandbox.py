#!/usr/bin/env python3
"""HIMMEL-4912: reject recognizable unwrapped launches in owned corpus harnesses.

Other fixture/replay harnesses warn until migrated (console-scoped first slice).
This is an architecture lint, not a shell interpreter or a malicious-code audit:
dynamic launch forms in the owned Python harness fail closed when unprovable.
"""
import ast
import pathlib
import re
import sys

ENFORCED = (
    "scripts/eval/guard-corpus/diff",
    "scripts/hooks/test-block-destructive-commands.sh",
)
FOLLOW_UPS = (
    "scripts/hooks/test-hook-chain-latency.sh",
    "scripts/hooks/test-block-chokepoint-env-prefix.sh",
    "scripts/codex/hook-smoke-demo.sh",
    "scripts/codex/probe-codex-hooks.ps1",
    "scripts/hooks/bench-hook-stack.mjs",
)


def python_launches(text):
    tree = ast.parse(text)
    assignments = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    assignments.setdefault(target.id, []).append(node.value)

    def runner_name(node):
        if not isinstance(node, ast.Name):
            return False
        values = assignments.get(node.id, [])
        def path_expression(value):
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return True
            if isinstance(value, ast.Name) and value.id == "__file__":
                return True
            return (isinstance(value, ast.Call) and not value.keywords
                    and ast.unparse(value.func) in ("os.path.join", "os.path.dirname", "os.path.abspath")
                    and bool(value.args) and all(path_expression(arg) for arg in value.args))

        def runner_expression(value):
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return pathlib.PurePosixPath(value.value).name == "sandbox-run.sh"
            if not (isinstance(value, ast.Call) and path_expression(value)):
                return False
            name = ast.unparse(value.func)
            if name == "os.path.abspath" and len(value.args) == 1:
                return runner_expression(value.args[0])
            return (name == "os.path.join" and isinstance(value.args[-1], ast.Constant)
                    and value.args[-1].value == "sandbox-run.sh")

        return len(values) == 1 and runner_expression(values[0])

    errors = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "subprocess"
                and node.func.attr in ("Popen", "run", "call", "check_call", "check_output")):
            continue
        args = node.args[0] if node.args else None
        # Require the prefix at the call site, never infer it from a mutable argv.
        while isinstance(args, ast.BinOp) and isinstance(args.op, ast.Add):
            args = args.left
        if isinstance(args, (ast.List, ast.Tuple)) and args.elts:
            first = args.elts[0]
            if isinstance(first, ast.Constant) and first.value == "git":
                continue
            if (isinstance(first, ast.Constant) and first.value == "bash"
                    and len(args.elts) >= 2 and runner_name(args.elts[1])):
                continue
        errors.append((node.lineno, "subprocess launch is not provably sandboxed"))
    return errors


def shell_launches(text):
    errors = []
    lines = text.splitlines()
    # Recognize only the owned harness binding and the literal fixture form.
    # A marker or variable name is not evidence of what Bash will execute.
    runner_bindings = [
        (number, line.strip()) for number, line in enumerate(lines, 1)
        if not line.lstrip().startswith("#") and re.search(r'\bRUNNER\s*\+?=', line)
    ]
    approved = {
        'RUNNER="sandbox-run.sh"',
        'RUNNER="$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh"',
    }
    runner_line = (runner_bindings[0][0] if len(runner_bindings) == 1
                   and runner_bindings[0][1] in approved else None)
    hook = re.compile(r'\bbash\s+[\"\']?\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})|[\"\']?\$BASH[A-Za-z0-9_]*[\"\']?\s+[\"\']?\$HOOK\b')
    wrapper = re.compile(r'\bbash\s+[\"\']?\$(?:RUNNER\b|\{RUNNER\})[\"\']?[^;|&]*?\s+--\s')
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        for match in hook.finditer(line):
            if re.search(r'\$(?:RUNNER\b|\{RUNNER\})', match.group()):
                if runner_line is None or runner_line >= number:
                    errors.append((number, "shell runner binding is not provable"))
                continue
            prefix = line[:match.start()]
            # A wrapper protects only its own simple command, not a later one.
            prefix = re.split(r'[;|&]', prefix)[-1]
            if not wrapper.search(prefix):
                errors.append((number, "hook launch bypasses sandbox runner"))
    return errors


def main(root):
    failures = 0
    for relative in ENFORCED:
        path = root / relative
        if not path.is_file():
            print("FAIL %s: enforced harness missing" % relative)
            failures += 1
            continue
        text = path.read_text()
        if "sandbox-run.sh" not in text:
            print("FAIL %s: sandbox runner missing" % relative)
            failures += 1
        try:
            errors = python_launches(text) if path.name == "diff" else shell_launches(text)
        except SyntaxError as error:
            errors = [(error.lineno, "cannot parse harness")]
        for line, reason in errors:
            print("FAIL %s:%s: %s" % (relative, line, reason))
            failures += 1
    warned = set(FOLLOW_UPS)
    # Discover additional fixture/corpus owners, not just the curated inventory.
    for base in (root / "scripts", root / "marketplace"):
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if (path.suffix not in (".sh", ".py", ".mjs", ".ps1") or not path.is_file()
                    or not re.search(r'test|bench|smoke|probe|replay', path.name, re.I)):
                continue
            text = path.read_text(errors="replace")
            if (re.search(r'\b(corpus|replay)\b|tool_input', text, re.I)
                    and re.search(r'\bHOOK\b|scripts/hooks/|hook_path', text)):
                warned.add(str(path.relative_to(root)))
    for relative in sorted(warned - set(ENFORCED)):
        if (root / relative).is_file() and relative != "scripts/ci/lint-corpus-sandbox.py":
            print("WARN %s: migration follow-up; not certified sandboxed" % relative)
    print("corpus-sandbox lint: %s" % ("FAIL" if failures else "PASS"))
    return bool(failures)


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2]
    sys.exit(main(root))
