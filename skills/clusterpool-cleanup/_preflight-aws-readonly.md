# AWS Read-Only Pre-flight

Run these steps when the skill requires AWS read-only access:

1. Find available AWS profiles: run `grep '^\[' ~/.aws/config | tr -d '[]' | sed 's/^profile //'`
   - Present them as a numbered menu and wait for the user to select one.
   - Note to the user: "A read-only profile is sufficient for this step."
   - Store the selected profile as AWS_READ_PROFILE.
2. Verify: `aws sts get-caller-identity --profile <AWS_READ_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <AWS_READ_PROFILE>. Please refresh and retry." — STOP
