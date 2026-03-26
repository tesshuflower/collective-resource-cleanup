# AWS Write Pre-flight

Run these steps when the skill requires AWS write access for deletions:

1. Find available AWS profiles: run `grep '^\[' ~/.aws/config | tr -d '[]' | sed 's/^profile //'`
   - Present them as a numbered menu and wait for the user to select one.
   - Note to the user: "A profile with write access is required for this step."
   - Store the selected profile as AWS_WRITE_PROFILE.
2. Verify: `aws sts get-caller-identity --profile <AWS_WRITE_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <AWS_WRITE_PROFILE>. Please refresh and retry." — STOP
