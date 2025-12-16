#!/bin/bash
# Install git hooks for ALUMIINI development

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Installing git hooks..."

cp "$SCRIPT_DIR/pre-commit" "$REPO_ROOT/.git/hooks/pre-commit"
chmod +x "$REPO_ROOT/.git/hooks/pre-commit"

echo "✅ Git hooks installed!"
echo ""
echo "The following checks will run before each commit:"
echo "  - mix format --check-formatted"
echo "  - No bare raises in lib/"
echo "  - No IO.puts/IO.inspect in lib/"
echo "  - No TODO/FIXME in lib/"
echo "  - mix credo --strict (if installed)"
echo "  - mix test"
