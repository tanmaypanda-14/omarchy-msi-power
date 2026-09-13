#!/bin/bash
# Wire the tanmay.msi-power setup scripts into the omarchy plugin manager so
# that installing/enabling and removing the plugin also grants (and revokes)
# the MSI EC access automatically:
#
#   omarchy plugin add tanmay.msi-power → runs setup/install.sh   (sudo grant)
#   omarchy plugin update tanmay.msi-power → re-runs setup/install.sh (idempotent)
#   omarchy plugin remove tanmay.msi-power → runs setup/uninstall.sh (sudo revoke)
#
# omarchy's CLI has no plugin hook mechanism, so this patches its three scripts
# in place (they live under /usr/bin and are replaced on omarchy package
# updates — re-run `sudo setup/cli-hooks.sh install` after such an update).
#
#   sudo setup/cli-hooks.sh install    # patch the CLIs (idempotent)
#   sudo setup/cli-hooks.sh remove     # undo the patch (idempotent)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run as root (sudo $0 $*)"
  exit 1
fi

op="${1:-install}"

python3 - "$op" <<'PY'
import pathlib
import sys

OP = "install" if sys.argv[1] == "install" else "remove"

OPEN = "# >>> tanmay.msi-power lifecycle hook >>>"
CLOSE = "# <<< tanmay.msi-power lifecycle hook <<<"

# anchor -> snippet (the anchor text is replaced by anchor + snippet)
RULES = {
    "/usr/bin/omarchy-plugin-add": (
        'echo "Added $id into $target"',
        f'{OPEN}\n'
        'if [[ -f $target/setup/install.sh && -x $target/setup/install.sh ]]; then\n'
        '  echo "Running setup/install.sh:"\n'
        '  "$target/setup/install.sh" || {\n'
        '    echo "omarchy-plugin-add: setup/install.sh failed for \'$id\'" >&2\n'
        "    echo \"run it manually once:  sudo '$target/setup/install.sh'\" >&2\n"
        '  }\n'
        'fi\n'
        f'{CLOSE}',
    ),
    "/usr/bin/omarchy-plugin-remove": (
        'if [[ $was_enabled == "true" ]]; then\n'
        '  omarchy-shell shell setPluginEnabled "$id" false >/dev/null\n'
        'fi',
        f'{OPEN}\n'
        'if [[ -f $target/setup/uninstall.sh && -x $target/setup/uninstall.sh ]]; then\n'
        '  echo "Running setup/uninstall.sh:"\n'
        '  "$target/setup/uninstall.sh" || {\n'
        "    echo \"omarchy-plugin-remove: setup/uninstall.sh failed for '$id'; it did not revoke EC access.\" >&2\n"
        "    echo \"  run it manually once:  sudo '$target/setup/uninstall.sh'\" >&2\n"
        '  }\n'
        'fi\n'
        f'{CLOSE}',
    ),
    "/usr/bin/omarchy-plugin-update": (
        'echo "Updated $id."',
        f'{OPEN}\n'
        'if [[ -f $dir/setup/install.sh && -x $dir/setup/install.sh ]]; then\n'
        '  echo "Running setup/install.sh:"\n'
        '  "$dir/setup/install.sh" ||\n'
        "    echo \"omarchy-plugin-update: setup/install.sh failed for '$id'\" >&2\n"
        'fi\n'
        f'{CLOSE}',
    ),
}

def patch_script(path: str, anchor: str, snippet: str) -> str:
    p = pathlib.Path(path)
    try:
        text = p.read_text()
    except OSError as e:
        return f"{path}: skipped ({e})"
    if OPEN in text:
        return f"{path}: already hooked"
    if anchor not in text:
        return f"{path}: WARNING anchor not found — plugin lifecycle not wired"
    text = text.replace(anchor, anchor + "\n" + snippet, 1)
    p.write_text(text)
    return f"{path}: patched"

def unpatch_script(path: str) -> str:
    p = pathlib.Path(path)
    try:
        text = p.read_text()
    except OSError as e:
        return f"{path}: skipped ({e})"
    if OPEN not in text:
        return f"{path}: not hooked"
    start = text.index(OPEN)
    end = text.index(CLOSE, start) + len(CLOSE)
    text = text[:start] + text[end + 1 :]
    p.write_text(text)
    return f"{path}: unpatched"

for path, (anchor, snippet) in RULES.items():
    print(patch_script(path, anchor, snippet) if OP == "install"
          else unpatch_script(path))
PY

echo "done. Add/update/remove of tanmay.msi-power now runs its setup scripts."
echo "Verify the plugin flow with:  omarchy plugin remove tanmay.msi-power"