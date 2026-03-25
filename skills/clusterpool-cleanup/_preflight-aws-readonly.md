# AWS Read-Only Pre-flight

Run these steps when the skill requires AWS read-only access:

1. Ask the user to select an AWS read-only profile:
   ```
   AWS read-only profile:
     1) aws-acm-dev11-readonly
     2) Enter a different profile
   ```
   If the user selects 1, use that profile. If the user selects 2, ask: "AWS read-only profile:" and wait for input. Store as READ_PROFILE.
2. Verify: `aws sts get-caller-identity --profile <READ_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <READ_PROFILE>. Please refresh and retry." — STOP
