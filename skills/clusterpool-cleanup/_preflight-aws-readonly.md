# AWS Read-Only Pre-flight

Run these steps when the skill requires AWS read-only access:

1. Check config: read `~/.config/collective-resource-cleanup/config.json` if it exists.
   - If `aws_read_profile` is set: use it as AWS_READ_PROFILE and skip the menu. Tell the user: "Using saved read-only profile: <AWS_READ_PROFILE>"
   - If not set: find available AWS profiles: run `grep '^\[' ~/.aws/config | tr -d '[]' | sed 's/^profile //'`
     - Present them as a numbered menu and wait for the user to select one.
     - Note to the user: "A read-only profile is sufficient for this step."
     - Store the selected profile as AWS_READ_PROFILE.
     - Offer to save: "Save <AWS_READ_PROFILE> as your default read-only profile? (y/n)"
       - If y: write `aws_read_profile` to `~/.config/collective-resource-cleanup/config.json` (create file and directory if needed, preserve any existing keys).
2. Verify: `aws sts get-caller-identity --profile <AWS_READ_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <AWS_READ_PROFILE>. Please refresh and retry." — STOP
