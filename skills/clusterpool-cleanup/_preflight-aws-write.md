# AWS Write Pre-flight

Run these steps when the skill requires AWS write access for deletions:

1. Check config: read `~/.config/collective-resource-cleanup/config.json` if it exists.
   - If `aws_write_profile` is set: use it as AWS_WRITE_PROFILE and skip the menu. Tell the user: "Using saved write profile: <AWS_WRITE_PROFILE>"
   - If not set: find available AWS profiles: run `grep '^\[' ~/.aws/config | tr -d '[]' | sed 's/^profile //'`
     - Present them as a numbered menu and wait for the user to select one.
     - Note to the user: "A profile with write access is required for this step."
     - Store the selected profile as AWS_WRITE_PROFILE.
     - Offer to save: "Save <AWS_WRITE_PROFILE> as your default write profile? (y/n)"
       - If y: write `aws_write_profile` to `~/.config/collective-resource-cleanup/config.json` (create file and directory if needed, preserve any existing keys).
2. Verify: `aws sts get-caller-identity --profile <AWS_WRITE_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <AWS_WRITE_PROFILE>. Please refresh and retry." — STOP
