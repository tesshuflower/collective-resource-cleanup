# Common Pre-flight Steps

Run these steps at the start of every clusterpool-cleanup skill:

1. Determine repo root: run `git rev-parse --show-toplevel` — store as REPO_ROOT
2. Ask the user to select the collective cluster URL:
   ```
   Collective cluster:
     1) https://api.collective.aws.red-chesterfield.com:6443
     2) Enter a different URL
   ```
   If the user selects 1, use that URL. If the user selects 2, ask: "Collective cluster URL:" and wait for input. Store as CLUSTER_URL.
3. Set `KUBECONFIG=~/.kube/collective` for all subsequent kubectl/oc commands.
4. Check authentication: run `KUBECONFIG=~/.kube/collective oc whoami`
   - If it fails: run `KUBECONFIG=~/.kube/collective oc login --web <CLUSTER_URL>` to authenticate via browser, then run `oc whoami` again to confirm
   - If it still fails: STOP (unless the skill explicitly says collective access is a soft dependency)
5. Get available namespaces: run `KUBECONFIG=~/.kube/collective oc projects -q`
   - Present them as a numbered menu (1, 2, 3...) and wait for the user to type a number to select one. Store the selected namespace as NAMESPACE.
