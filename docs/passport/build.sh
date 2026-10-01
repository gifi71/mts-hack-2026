#!/usr/bin/env bash
# Builds Паспорт.pdf from passport.md: pandoc -> HTML -> headless Chromium print.
set -euo pipefail
cd "$(dirname "$0")"
dot -Tpng -Gdpi=150 architecture.dot -o architecture.png
dot -Tsvg architecture.dot -o architecture.svg
pandoc passport.md --standalone --embed-resources --css passport.css \
  --metadata title="Паспорт решения" --metadata pagetitle="Паспорт решения" \
  -V title= -o passport.html
chromium --headless --no-sandbox --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="Паспорт.pdf" "file://$PWD/passport.html" 2>/dev/null
echo "Built $PWD/Паспорт.pdf"
