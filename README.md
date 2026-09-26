# deploy-action

Asks a host of [hueske-digital/infrastructure](https://github.com/hueske-digital/infrastructure)
to deploy a stack's new image: a POST to the stack's deploy hook
`https://<wan name of its host>/hooks/deploy-<stack>`, signed like GitHub's
webhooks (HMAC-SHA256 of the body with the stack's secret, header
`X-Hub-Signature-256`). How the host deploys is
[docs/decisions/0037](https://github.com/hueske-digital/infrastructure/blob/main/docs/decisions/0037-deploy-hook-per-stack.md).

```yaml
      # after the image was pushed
      - uses: hueske-digital/deploy-action@<commit sha> # v1
        with:
          url: ${{ vars.DEPLOY_URL }}
          secret: ${{ secrets.DEPLOY_SECRET }}
```

A whole workflow that builds the image for amd64 and arm64 in parallel,
pushes it to ghcr.io and deploys it is [examples/deploy.yml](examples/deploy.yml);
it names the image after the repository in lower case.

In the repository's settings: the variable `DEPLOY_URL`, and the secret
`DEPLOY_SECRET` with the stack's `<stack>_deploy_secret` from the host's
secrets. A stack that moves to another host changes only `DEPLOY_URL`.

The step succeeds once the hook took the call (202); the deploy runs on the
host afterwards and reports to the monitoring as `<stack> deploy`. It fails
on any other answer, with the reason:

| Answer | Meaning |
|---|---|
| 403 | the call was not signed |
| 404 | the host has no such hook: no `deploy: true` in the stack's entry, or another host |
| 500 | the signature does not match: another secret than the stack's |
| no answer, 502 to 504 | tried three times, 15 s each |

The URL is https, its path `/hooks/deploy-<stack>`, without a login or a
query; plain http only to `localhost`, `127.0.0.1` and `[::1]`, for tests. The body holds the repository, commit and run for the
webhook's log; the host reads none of it.

`test/run.sh` runs the action against the pinned adnanh/webhook image with
the hook as the infrastructure repository writes it (docker and node).
