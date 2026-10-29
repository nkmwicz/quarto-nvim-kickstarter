#!/usr/bin/env bash
# Creates (or updates) the prose venv that scripts/grammalecte_bridge.py runs
# on: the system Python plus spaCy, lemminflect, wn and Open English WordNet
# for the be-verb hints (config/beverbs.lua). --system-site-packages keeps
# apt's python3-grammalecte importable; spaCy isn't packaged in apt, and the
# system Python refuses pip installs. Safe to re-run. Called by
# ~/dotfiles/install.sh; needs uv.
set -euo pipefail

venv="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/prose-venv"
model=https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl

uv venv --quiet --allow-existing --system-site-packages --python /usr/bin/python3 "$venv"
uv pip install --quiet --python "$venv/bin/python" 'spacy>=3.8,<3.9' lemminflect wn "en_core_web_sm @ $model"
# WordNet data lives inside the venv (beverbs.py reads it from sys.prefix).
"$venv/bin/python" - <<'EOF'
import os, sys, wn
wn.config.data_directory = os.path.join(sys.prefix, "wn_data")
if not any(lex.id == "oewn" for lex in wn.lexicons()):
    wn.download("oewn:2024", progress_handler=None)
EOF
echo "prose venv ready: $venv"
