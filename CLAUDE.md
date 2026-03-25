# collective-resource-cleanup

Skills for this project live in `skills/clusterpool-cleanup/`. Invoke them using the Skill tool with names like `clusterpool-cleanup:cd-cleanup`.

## Available skills

- `clusterpool-cleanup:cd-cleanup` — clean up stuck ClusterDeployment objects
- `clusterpool-cleanup:cc-resource-cleanup` — deprovision orphaned AWS tagged resource groups via hiveutil
- `clusterpool-cleanup:investigate-orphans` — autonomously investigate orphaned AWS resources, produce a report and manifest
- `clusterpool-cleanup:cleanup-orphans` — act on the investigate-orphans manifest interactively
- `clusterpool-cleanup:full` — run all four skills in sequence
