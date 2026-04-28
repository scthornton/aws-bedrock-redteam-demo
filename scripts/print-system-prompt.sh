#!/usr/bin/env bash
# Print the demo's vulnerable system prompt to stdout. Pipe to pbcopy to paste
# into the AIRS Red Teaming target's "Additional Context > System Prompt" field
# when using the AWS Bedrock connection method.
#
# Usage:
#   ./scripts/print-system-prompt.sh             # to terminal
#   ./scripts/print-system-prompt.sh | pbcopy    # to clipboard (macOS)

set -euo pipefail
cd "$(dirname "$0")/.."
python3 -c "import sys; sys.path.insert(0,'.'); from vulnerabilities import build_system_prompt; print(build_system_prompt())"
