# deploy-action

Asks a host of [hueske-digital/infrastructure](https://github.com/hueske-digital/infrastructure)
to deploy a stack's new image: a POST to the stack's deploy hook
`https://<host>/hooks/deploy-<stack>`, signed like GitHub's webhooks
(HMAC-SHA256 of the body with the stack's secret, header
`X-Hub-Signature-256`). How the host deploys is
[docs/decisions/0037](https://github.com/hueske-digital/infrastructure/blob/main/docs/decisions/0037-deploy-hook-per-stack.md).

```yaml
      # after the image was pushed
      - uses: hueske-digital/deploy-action@2e880357b6dcbb764f0c1a7c936fd086be5b4410 # v1.0.0
        with:
          host: ${{ vars.DEPLOY_HOST }}   # the wan name of the stack's host
          stack: kunde                    # the stack's name in the host's list
          secret: ${{ secrets.DEPLOY_SECRET }}
```

A whole workflow is [examples/deploy.yml](examples/deploy.yml): on a pushed
tag `v*` it builds the image for amd64 and arm64 in parallel, pushes it to
ghcr.io as `:latest` and `:<tag>`, named after the repository in lower
case, and deploys it.

In the repository's settings: the variable `DEPLOY_HOST` with the wan name
of the stack's host (like `wan.htz1.wontfix.xyz`), and the secret
`DEPLOY_SECRET` with the stack's `<stack>_deploy_secret` from the host's
secrets. A stack that moves to another host changes only `DEPLOY_HOST`.

The step succeeds once the hook took the call (202); the deploy runs on the
host afterwards and reports to the monitoring as `<stack> deploy`. With
`health-url` the step waits for the new version instead: it asks the page
every 5 s until it answers 200 with the fields of `health-json`, and fails
after `health-timeout` seconds (600) with the last answer. A deploy takes a
few minutes, as the host pulls the image and waits for its health check.

```yaml
        with:
          host: ${{ vars.DEPLOY_HOST }}
          stack: kunde
          secret: ${{ secrets.DEPLOY_SECRET }}
          health-url: https://kunde.de/api/health
          health-json: '{"status": "ok", "commit": "{commit}"}'
```

`health-json` is a JSON object; the answer must hold each of its fields
with that value, and may hold more (`builtAt`, `uptimeSeconds`). The value
`"{commit}"` stands for the commit of the run: it matches its first 7
characters or more, as a site that tells the commit it was built from
writes it. Without `health-json` the page only has to answer 200.
`health-url` is https, plain http only to this machine, as for `host`; a
mistake in these inputs fails the step before the hook is called.

Without `health-url` the step fails on any other answer of the hook than
202, with the reason:

| Answer | Meaning |
|---|---|
| 403 | the call was not signed |
| 404 | the host has no deploy hook for the stack: no `deploy: true` in its entry there, or another host |
| 500 | the signature does not match: another secret than the stack's |
| no answer, 502 to 504 | tried three times, 15 s each |

`host` is a host name, with a port if needed, without `https://` or a path;
`stack` is lower case letters, digits and `-`. The call goes over https;
plain http only to `localhost`, `127.0.0.1` and `[::1]`, for tests. The body
holds the repository, commit and run for the webhook's log; the host reads
none of it.

`test/run.sh` runs the action against the pinned adnanh/webhook image with
the hook as the infrastructure repository writes it, and against a local
page for `health-url` (docker and node).
