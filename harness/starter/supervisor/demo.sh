#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lune="${LUNE:-$(command -v lune || true)}"
if [[ -z "$lune" && -x "$HOME/.rokit/bin/lune" ]]; then
    lune="$HOME/.rokit/bin/lune"
fi
if [[ -z "$lune" ]] || ! command -v "$lune" >/dev/null; then
    echo "Install Lune 0.11.0 from https://github.com/lune-org/lune/releases/tag/v0.11.0 or set LUNE=/path/to/lune." >&2
    exit 1
fi

python="${PYTHON:-python3}"
if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "Python 3.10+ is required. Set PYTHON=/path/to/python3 to choose an interpreter." >&2
    exit 1
fi

if [[ ! -x "$here/.venv/bin/python" ]]; then
    "$python" -m venv "$here/.venv"
fi
python="$here/.venv/bin/python"
"$python" -m pip --disable-pip-version-check install -q -r "$here/requirements.txt"
"$python" "$here/experiment.py" --lune "$lune"
"$python" "$here/local_demo.py" --lune "$lune"
