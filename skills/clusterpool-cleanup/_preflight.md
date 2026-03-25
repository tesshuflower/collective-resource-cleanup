# Common Pre-flight Steps

Run these steps at the start of every clusterpool-cleanup skill:

1. Determine repo root: run `git rev-parse --show-toplevel` — store as REPO_ROOT
2. Ask: "Collective cluster URL? (default: https://api.collective.aws.red-chesterfield.com:6443):" — if the user presses Enter, use the default. Store as CLUSTER_URL.
3. Set `KUBECONFIG=~/.kube/collective` for all subsequent kubectl/oc commands.
4. Try: `KUBECONFIG=~/.kube/collective kubectl get clusterpool --all-namespaces`
   - If it fails: run `KUBECONFIG=~/.kube/collective oc login <CLUSTER_URL>` to authenticate, then retry
   - If it still fails: STOP (unless the skill explicitly says collective access is a soft dependency)
5. Show the available namespaces from the clusterpool output. If there is only one, use it automatically. If there are multiple, list them and ask: "Collective cluster namespace?" Store as NAMESPACE.
