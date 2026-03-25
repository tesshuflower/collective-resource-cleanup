# collective-resource-cleanup

Claude Code skills for cleaning up orphaned AWS resources and stuck ClusterDeployments from a collective OpenShift cluster running ClusterPools.

## The problem

Clusters deployed via ClusterPools leave behind orphaned AWS resources (VPCs, EC2 instances, security groups, EIPs, S3 buckets, IAM roles) when they're decommissioned or when Hive fails to deprovision them due to expired AWS credentials.

## Skills

Skills are invoked through Claude Code using the `/clusterpool-cleanup:*` prefix.

| Skill | Description |
|---|---|
| `clusterpool-cleanup:cd-cleanup` | Clean up stuck ClusterDeployment objects (DeprovisionFailed + stuck Provisioning). No AWS credentials needed. |
| `clusterpool-cleanup:cc-resource-cleanup` | Scan all regions for `kubernetes.io/cluster/*` tagged resources not claimed by any active CD, and deprovision them using `hiveutil aws-tag-deprovision`. |
| `clusterpool-cleanup:investigate-orphans` | Autonomously investigates AWS resources, reasons about relationships, and produces a report + manifest. Read-only — no destructive actions. |
| `clusterpool-cleanup:cleanup-orphans` | Acts on a manifest from `investigate-orphans`. Interactive selection UI with per-item safety re-checks before deletion. |
| `clusterpool-cleanup:full` | Runs all four skills in sequence with credential reuse. |

`investigate-orphans` uses Claude's intelligence to reason about relationships between AWS resources rather than following a fixed checklist. It reads from a knowledge base of confirmed patterns (`knowledge/`) that grows over time to improve confidence assessments.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) installed
- `kubectl` / `oc` logged into the collective cluster
- AWS CLI configured with read-only and write profiles
- `hiveutil` binary (for `cc-resource-cleanup`) — default path: `~/DEV/openshift/hive/bin/hiveutil` (prompted if not found)
- `bats-core` (for running tests)
- Python 3

## Setup

Register the skills by symlinking them into the Claude Code superpowers plugin directory, then restart Claude Code (or reload skills):

```bash
PLUGIN_DIR=$(ls -d ~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills 2>/dev/null | tail -1)
ln -sf "$(pwd)/skills/clusterpool-cleanup" "${PLUGIN_DIR}/clusterpool-cleanup"
```

## Recommended workflow

1. Log into the collective cluster:
   ```bash
   oc login <collective-cluster-url>
   ```
2. Run the full cleanup:
   ```
   /clusterpool-cleanup:full
   ```
   Or run individual skills as needed.
3. Review the `investigate-orphans` report and approve deletions interactively via `cleanup-orphans`.

## AWS profiles

Two AWS CLI profiles are used:

- **Read-only** (e.g. `aws-acm-dev11-readonly`) — scanning and investigation
- **Write** (e.g. `aws-acm-dev11`) — deletions (prompted before any destructive action)

Each skill prompts for the relevant profile when it's first needed.

## Knowledge base

`knowledge/` accumulates learnings across runs:

- `orphan-patterns.md` — confirmed patterns indicating a resource is orphaned
- `active-signatures.md` — known active resource signatures to avoid false positives
- `run-history/` — per-run summaries written by Claude after each investigation

Claude reads this at the start of `investigate-orphans` and updates it after runs. You control what gets committed to git.

## Running tests

```bash
bats tests/
```

## Repository layout

```
skills/clusterpool-cleanup/   # Claude skill files
scripts/
  lib/                        # Shared bash libraries
    aws.sh                    # AWS CLI operations
    collective.sh             # ClusterDeployment queries
    manifest.sh               # Manifest read/write
    preflight.sh              # Pre-flight checks
  scan-cds.sh                 # Scan for stuck ClusterDeployments
  scan-cc-resources.sh        # Scan for orphaned AWS resource groups
knowledge/                    # Accumulated learnings
tests/                        # bats test suite
docs/                         # Design spec and implementation plan
```
