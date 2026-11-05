#!/bin/zsh
set -euo pipefail
readonly SCRIPT_DIR="${0:A:h}"
exec "$SCRIPT_DIR/../Scripts/build-app.sh" community
