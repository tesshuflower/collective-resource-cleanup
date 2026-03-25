#!/usr/bin/env bash
# Manifest read/write functions for clusterpool-cleanup skills.
# Manifest format: JSON with items array and metadata fields.

MANIFEST_DEFAULT_PATH="/tmp/clusterpool-cleanup-manifest.json"

# Initialize a new manifest file.
# Usage: manifest_init <path>
manifest_init() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  python3 -c "
import json, datetime
manifest = {
    'version': '1',
    'created_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'cc_resource_cleanup_run': False,
    'items': []
}
with open('${path}', 'w') as f:
    json.dump(manifest, f, indent=2)
"
}

# Set cc_resource_cleanup_run flag.
# Usage: manifest_set_cc_resource_cleanup_run <path> <true|false>
manifest_set_cc_resource_cleanup_run() {
  local path="$1"
  local value="$2"
  python3 - "$path" "$value" <<'PYEOF'
import json, sys
path = sys.argv[1]
value = sys.argv[2]
with open(path) as f:
    m = json.load(f)
m['cc_resource_cleanup_run'] = (value == 'true')
with open(path, 'w') as f:
    json.dump(m, f, indent=2)
PYEOF
}

# Get cc_resource_cleanup_run value.
# Usage: manifest_get_cc_resource_cleanup_run <path>
# Prints true or false.
manifest_get_cc_resource_cleanup_run() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  if [[ ! -f "$path" ]]; then
    echo "false"
    return 0
  fi
  python3 -c "
import json
try:
    with open('${path}') as f:
        m = json.load(f)
    print('true' if m.get('cc_resource_cleanup_run') else 'false')
except Exception:
    print('false')
"
}

# Add an item to the manifest.
# Usage: manifest_add_item <path> <item-json>
# Item JSON shape: {resource, type, origin, created, why_orphaned, confidence, action, region?, infra_id?}
manifest_add_item() {
  local path="$1"
  local item="$2"
  python3 - "$path" "$item" <<'PYEOF'
import json, sys
path = sys.argv[1]
item = json.loads(sys.argv[2])
with open(path) as f:
    m = json.load(f)
m['items'].append(item)
with open(path, 'w') as f:
    json.dump(m, f, indent=2)
PYEOF
}

# Read all items from manifest.
# Usage: manifest_get_items <path>
# Prints JSON array.
manifest_get_items() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  python3 -c "
import json
with open('${path}') as f:
    m = json.load(f)
print(json.dumps(m.get('items', [])))
"
}

# CLI dispatch — allows calling functions directly:
#   bash manifest.sh manifest_init /tmp/foo.json
#   bash manifest.sh manifest_add_item /tmp/foo.json '<json>'
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  "$@"
fi
