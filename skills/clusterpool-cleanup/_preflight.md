# Common Pre-flight Steps

Run these steps at the start of every clusterpool-cleanup skill:

1. Determine repo root: run `git rev-parse --show-toplevel` — store as REPO_ROOT
2. Check config: read `~/.config/collective-resource-cleanup/config.json` if it exists.
   - If `collective_url` is set: use it as CLUSTER_URL and skip the menu. Tell the user: "Using saved cluster URL: <CLUSTER_URL>"
   - If not set: ask the user to select the collective cluster URL:
     ```
     Collective cluster:
       1) https://api.collective.aws.red-chesterfield.com:6443
       2) Enter a different URL
     ```
     If the user selects 1, use that URL. If the user selects 2, ask: "Collective cluster URL:" and wait for input. Store as CLUSTER_URL.
     Offer to save: "Save this cluster URL to config? (y/n)"
       - If y: write `collective_url` to `~/.config/collective-resource-cleanup/config.json` (create file and directory if needed, preserve any existing keys).
3. Set `KUBECONFIG=~/.kube/collective` for all subsequent kubectl/oc commands.
4. Check authentication: run `KUBECONFIG=~/.kube/collective oc whoami`
   - If it fails: run `KUBECONFIG=~/.kube/collective oc login --web <CLUSTER_URL>` to authenticate via browser, then run `oc whoami` again to confirm
   - If it still fails: STOP (unless the skill explicitly says collective access is a soft dependency)
5. Get available namespaces: run `KUBECONFIG=~/.kube/collective oc projects -q`
   - Present them as a numbered menu (1, 2, 3...) and wait for the user to type a number to select one. Store the selected namespace as NAMESPACE.
