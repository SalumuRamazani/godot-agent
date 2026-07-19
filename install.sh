#!/bin/sh
# Install Godot Agent into a Godot project and enable it.
#
#   ./install.sh /path/to/your-godot-project
#
# Or from anywhere, without cloning:
#   curl -fsSL https://raw.githubusercontent.com/SalumuRamazani/godot-agent/main/install.sh | sh -s -- /path/to/project
#
# Godot has no global-plugin mechanism, so run this once per project (new or
# existing). It copies addons/godot_agent and enables it in project.godot.
set -e

PROJECT="$1"
if [ -z "$PROJECT" ] || [ ! -f "$PROJECT/project.godot" ]; then
	echo "usage: install.sh /path/to/godot-project   (must contain project.godot)" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -d "$SCRIPT_DIR/addons/godot_agent" ]; then
	SRC="$SCRIPT_DIR/addons/godot_agent"
else
	# Piped from curl: fetch the repo to a temp dir first.
	TMP="$(mktemp -d)"
	echo "Downloading godot-agent…"
	curl -fsSL https://github.com/SalumuRamazani/godot-agent/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
	SRC="$TMP/godot-agent-main/addons/godot_agent"
fi

mkdir -p "$PROJECT/addons"
rm -rf "$PROJECT/addons/godot_agent"
cp -R "$SRC" "$PROJECT/addons/godot_agent"

python3 - "$PROJECT/project.godot" <<'EOF'
import re, sys
path = sys.argv[1]
entry = 'res://addons/godot_agent/plugin.cfg'
text = open(path).read()
if entry in text:
    print("Already enabled in project.godot")
elif '[editor_plugins]' in text:
    def add(m):
        inner = m.group(1)
        new = inner[:-1] + (', ' if inner.strip('()') and inner != 'PackedStringArray(' else '') + f'"{entry}")'
        return 'enabled=' + new
    text, n = re.subn(r'enabled=(PackedStringArray\([^)]*\))', add, text, count=1)
    if n == 0:
        text = text.replace('[editor_plugins]', f'[editor_plugins]\n\nenabled=PackedStringArray("{entry}")', 1)
    open(path, 'w').write(text)
    print("Enabled in existing [editor_plugins]")
else:
    text += f'\n[editor_plugins]\n\nenabled=PackedStringArray("{entry}")\n'
    open(path, 'w').write(text)
    print("Added [editor_plugins] and enabled")
EOF

echo "Godot Agent installed into $PROJECT — open the project and look for the 'Agent' panel (lower right)."
