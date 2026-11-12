# Setup whk

Installs [`whk`](https://webhooks.cc/docs/cli), the [webhooks.cc](https://webhooks.cc) CLI, on a GitHub Actions runner.

webhooks.cc gives you URLs and email addresses that capture whatever is sent to them, so you can see and assert on the webhooks and emails your app sends. `whk` creates those URLs, reads what they captured, sends test webhooks, and forwards captured webhooks to a local port, and the [TypeScript](https://webhooks.cc/docs/sdk), [Python](https://webhooks.cc/docs/sdk/python) and [Go](https://webhooks.cc/docs/sdk/go) SDKs do the same from test code.

```yaml
- uses: kroqdotdev/setup-whk@v1
- run: whk --version
```

The action downloads the release archive for the runner's platform from the [webhooks.cc releases](https://github.com/kroqdotdev/webhooks-cc/releases), checks it against the release's `checksums.txt`, and adds `whk` to `PATH`. It is a composite action around one shell script: no Node runtime, no dependencies, no token.

## Usage

### Install whk

```yaml
steps:
  - uses: kroqdotdev/setup-whk@v1
    with:
      version: 1.10.0 # optional; the newest release when left out
  - run: whk --version
```

### Capture a webhook in a CI job

Create a capture URL, point the code under test at it, and check what arrived. Add an [API key](https://webhooks.cc/account/api-keys) as the repository secret `WHK_API_KEY`; the free plan is enough for a small suite.

```yaml
jobs:
  webhook:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: kroqdotdev/setup-whk@v1
        with:
          api-key: ${{ secrets.WHK_API_KEY }}

      - name: Create a capture URL
        id: endpoint
        run: |
          whk create "ci-$GITHUB_RUN_ID" --json > endpoint.json
          echo "slug=$(jq -r .slug endpoint.json)" >> "$GITHUB_OUTPUT"
          echo "url=$(jq -r .url endpoint.json)" >> "$GITHUB_OUTPUT"

      - name: Run the code that sends the webhook
        run: ./scripts/place-test-order.sh # your code
        env:
          WEBHOOK_URL: ${{ steps.endpoint.outputs.url }}

      - name: Check what arrived
        run: |
          whk requests list "$SLUG" --json > requests.json
          jq -e '.requests | length == 1' requests.json
          jq -e '.requests[0].method == "POST"' requests.json
          jq -e '.requests[0].body | fromjson | .event == "order.paid"' requests.json
        env:
          SLUG: ${{ steps.endpoint.outputs.slug }}

      - name: Delete the capture URL
        if: always() && steps.endpoint.outputs.slug != ''
        run: whk delete "$SLUG" --force
        env:
          SLUG: ${{ steps.endpoint.outputs.slug }}
```

A request is stored before its sender gets an answer, so it is there to list as soon as your code has sent it. `whk send <slug> -d '{"event":"order.paid"}'` sends a test webhook of your own to an endpoint, and `whk requests export <slug> --format curl` writes what arrived as cURL commands you can keep as a build artifact.

### Try it without an account

`whk sandbox` needs no key: it registers an anonymous sandbox (a few seconds of proof of work) with up to 3 capture URLs for 24 hours.

```yaml
steps:
  - uses: kroqdotdev/setup-whk@v1

  - name: Capture one webhook
    run: |
      whk sandbox create --json > endpoint.json
      curl -fsS -X POST "$(jq -r .url endpoint.json)" \
        -H 'Content-Type: application/json' -d '{"event":"order.paid"}'
      whk sandbox wait "$(jq -r .slug endpoint.json)" --timeout 30s --json > request.json
      jq -e '.body | fromjson | .event == "order.paid"' request.json
```

Sandboxes are limited per network address, and hosted runners share theirs, so use an API key for anything that has to pass every time.

### Use with the Python, TypeScript or Go SDK

With `api-key`, the action sets `WHK_API_KEY` for the steps that follow: the Python and Go SDKs read it on their own, and TypeScript tests pass it as `apiKey`. With `whk` installed, the SDKs' `share()` can also put a port of the runner at a public link.

Python, with the [pytest plugin](https://pypi.org/project/pytest-webhooks-cc/):

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: actions/setup-python@v5
    with:
      python-version: "3.13"
  - uses: kroqdotdev/setup-whk@v1
    with:
      api-key: ${{ secrets.WHK_API_KEY }}
  - run: pip install -e . pytest-webhooks-cc
  - run: pytest
```

```python
def test_sends_order_paid(webhooks_cc, webhooks_cc_endpoint):
    send_order_webhook(webhooks_cc_endpoint.url)
    request = webhooks_cc.requests.wait_for(webhooks_cc_endpoint.slug, timeout="30s")
    assert request.json()["event"] == "order.paid"
```

TypeScript, with [`@webhooks-cc/sdk`](https://www.npmjs.com/package/@webhooks-cc/sdk):

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: actions/setup-node@v7
    with:
      node-version: 24
  - uses: kroqdotdev/setup-whk@v1
    with:
      api-key: ${{ secrets.WHK_API_KEY }}
  - run: npm ci
  - run: npm test
```

```ts
import { WebhooksCC } from "@webhooks-cc/sdk";
import { captureDuring } from "@webhooks-cc/sdk/testing";

const client = new WebhooksCC({ apiKey: process.env.WHK_API_KEY! });
const [request] = await captureDuring(client, (endpoint) =>
  sendOrderWebhook(endpoint.url!),
);
```

Go, with [`webhooks.cc/go`](https://webhooks.cc/docs/sdk/go):

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: actions/setup-go@v7
    with:
      go-version: stable
  - uses: kroqdotdev/setup-whk@v1
    with:
      api-key: ${{ secrets.WHK_API_KEY }}
  - run: go test ./...
```

```go
client := whktest.Client(t)             // skipped when WHK_API_KEY is not set
endpoint := whktest.Endpoint(t, client) // deleted when the test ends
```

Pull requests from forks get no secrets. The input is then empty, nothing is exported, and tests that need the key are skipped by the Python and Go test helpers.

## Inputs

| Input     | Default  | Description                                                                                                                                                         |
| --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version` | `latest` | The whk version to install, such as `1.10.0` or `v1.10.0`. `latest` installs the newest release. Versions from 1.0.0 on.                                            |
| `api-key` | none     | A webhooks.cc API key, passed from a secret. Exported to the steps that follow as `WHK_API_KEY`, together with `WHK_AUTH=key`. Masked in the log and never printed. |

## Outputs

| Output    | Description                                                     |
| --------- | --------------------------------------------------------------- |
| `version` | The installed version, without the leading `v`, as in `1.10.0`. |
| `path`    | The full path of the installed `whk` binary.                    |

## The API key

`whk` does not use a key just because `WHK_API_KEY` is set: on a developer's machine that variable is often there for the SDKs, and may belong to another account than the one `whk auth login` signed in. It reads the key only with `WHK_AUTH=key`. A runner has no login, so the action sets both, and `whk auth status` then answers "Using the API key in WHK_API_KEY".

The key reaches the install script through the environment, is masked with `::add-mask::` before anything else happens, and is written to `GITHUB_ENV` only. Pass it from a secret: GitHub prints an action's inputs in the log, and only values it knows as secrets are masked there.

To use `whk` as a different account in one step, set `WHK_API_KEY` in that step's `env`.

## Runners

| Runner                                      | Build                       |
| ------------------------------------------- | --------------------------- |
| Linux x64 (`ubuntu-latest`, `ubuntu-22.04`) | `x86_64-unknown-linux-gnu`  |
| Linux arm64 (`ubuntu-24.04-arm`)            | `aarch64-unknown-linux-gnu` |
| macOS arm64 (`macos-latest`)                | `aarch64-apple-darwin`      |
| macOS x64 (`macos-15-intel`)                | `x86_64-apple-darwin`       |
| Windows x64 (`windows-latest`)              | `x86_64-pc-windows-msvc`    |

Windows ARM64 has no build yet, and the action fails there with a message that says so. The Linux builds need glibc 2.34 or later (Ubuntu 22.04, Debian 12), so they do not run in Alpine containers; below glibc 2.39 the system's loader prints a warning about a symbol version on each call, and `whk` works all the same. Self-hosted runners need `bash`, `curl`, `tar` (`unzip` or PowerShell on Windows) and `sha256sum` or `shasum`.

## Verification

Every release publishes `checksums.txt` with the SHA-256 of each archive, and the action refuses an archive that does not match. The checksums file is itself signed with [cosign](https://docs.sigstore.dev/cosign/) by the release workflow. When `cosign` is on the runner, the action checks that signature as well and fails if it does not verify:

```yaml
steps:
  - uses: sigstore/cosign-installer@v3
  - uses: kroqdotdev/setup-whk@v1
```

Without `cosign` the log says the signature was not checked. This is the same sequence as the install script at `https://webhooks.cc/install.sh`.

## Documentation

- [CLI commands](https://webhooks.cc/docs/cli/commands)
- [Forwarding webhooks to a local port with `whk tunnel`](https://webhooks.cc/docs/cli/tunnel)
- [Testing with pytest](https://webhooks.cc/docs/sdk/testing/pytest)
- [The source of whk](https://github.com/kroqdotdev/webhooks-cc/tree/main/apps/cli-rs)

## License

MIT
