#!/usr/bin/env python3
import sys

model = ""
slug = ""
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--model" and i+1 < len(args):
        model = args[i+1]; i += 2
    elif args[i] == "--slug" and i+1 < len(args):
        slug = args[i+1]; i += 2
    else:
        i += 1

sys.stdin.read()

# The anchor critic's stand-in. Two accepted model ids: the old string is still
# used by the fixture registries in test-critic-panel.sh (arbitrary critic id
# for the merge/renumber/tier tests); the new string is the current ANCHOR_MODEL
# that the anchor-fallback tests (E, I2) feed through this stub to prove the
# anchor MODEL ran. Keep both so a future ANCHOR_MODEL bump only touches this line.
if model in ("qwen/qwen3-coder-480b-a35b-instruct", "qwen/qwen3.6-35b-a3b"):
    print("# qwen3coder First-Pass Review")
    print("")
    print("## Critical Issues (1 found)")
    print("- [qwen3coder-1]: null dereference in handler [foo.sh:3]")
    print("")
    print("## Important Issues (1 found)")
    print("- [qwen3coder-2]: unused variable x [foo.sh:5]")
    print("")
    print("## Suggestions (1 found)")
    print("- [qwen3coder-3]: rename for clarity [foo.sh:7]")
    sys.exit(0)
elif model == "openai/gpt-oss-120b":
    print("# gptoss First-Pass Review")
    print("")
    print("## Critical Issues (0 found)")
    print("")
    print("## Important Issues (1 found)")
    print("- [gptoss-1]: missing error check [bar.sh:2]")
    print("")
    print("## Suggestions (0 found)")
    sys.exit(0)
elif model == "moonshotai/kimi-k2.6":
    print("kimi: service unavailable", file=sys.stderr)
    sys.exit(1)
else:
    print("stub-cfp: unknown model:", model, file=sys.stderr)
    sys.exit(1)
