# Hexium Upload

A GitHub Action that uploads a [Thunderstore](https://thunderstore.io)-compatible
package ZIP to [Hexium](https://hexium.gg), a Thunderstore-API-compatible mod
repository.

Created for lack of official Hexium CLI or GitHub Action. Fits well in a CI pipeline since the same
ZIP `tcli build` produced is accepted as-is.

## How it works

Hexium mirrors Thunderstore's experimental upload API. The action follows the
four-step flow:

1. `POST /api/experimental/usermedia/initiate-upload/` — asks for presigned upload part URLs
2. `PUT` each part to its presigned URL (no `Authorization` header on these)
3. `POST /api/experimental/usermedia/{uuid}/finish-upload/`
4. `POST /api/experimental/submission/submit/`

The target community is resolved from the **request subdomain**
(`https://{community}.hexium.gg/`), not from anything in the submit body.

## Requirements

- `bash`, `curl`, and `jq` on the runner (present on GitHub-hosted `ubuntu-*` and `macos-*` runners).
- A Hexium API token: **Settings → API Tokens** on hexium.gg. 
- A team (namespace) you own on Hexium, which the token can publish under.

## Inputs

| Input         | Required | Description                                                                  |
| ------------- | -------- | ---------------------------------------------------------------------------- |
| `community`   | yes      | Community slug (e.g. `valheim`). Determines the upload subdomain.            |
| `file`        | yes      | Path to the Thunderstore-compatible package ZIP.                             |
| `token`       | yes      | Hexium API token. A missing `Bearer ` prefix is added automatically.         |
| `namespace`   | yes      | Author/team namespace to publish under.                                      |
| `categories`  | no       | Comma-separated list of categories (default `""`).                           |
| `nsfw`        | no       | `true`/`false` (default `false`).                                            |
| `host`        | no       | Repository host (default `hexium.gg`).                                       |
| `base-url`    | no       | Override the full API base URL (advanced; self-hosted mirrors or testing).   |

## Outputs

| Output    | Description                                      |
| --------- | ------------------------------------------------ |
| `package` | Full name of the uploaded package (`Ns-Mod`).    |
| `version` | Version number of the uploaded package.          |

## Usage

```yaml
- name: Upload to Hexium
  uses: your-org/hexium-uploader@74d6670d8ed4c7ec9f3ebd0aac339e156cedada2 # Pin the action to the latest commit on implementation
  with:
    community: valheim
    file: build/YourMod-1.0.0.zip
    token: ${{ secrets.HEXIUM_API_TOKEN }}
    namespace: your-team
    categories: client-side
```

Publishing to both Thunderstore and Hexium from the same release workflow. The ZIP
is named `{namespace}-{name}-{version}.zip` by `tcli`, so the same file is uploaded
to both hosts:

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... build your mod + run `tcli build` to produce build/*.zip ...

      - name: Publish to Thunderstore
        env:
          TCLI_AUTH_TOKEN: ${{ secrets.TCLI_AUTH_TOKEN }}
        run: tcli publish --config-path thunderstore.toml --package-version "$(tr -d '[:space:]' < version.txt)"

      - name: Publish to Hexium
        uses: your-org/hexium-uploader@v1
        with:
          community: valheim
          file: build/YourOrg-YourMod-$(tr -d '[:space:]' < version.txt).zip
          token: ${{ secrets.HEXIUM_API_TOKEN }}
          namespace: your-team
```

The action only reads the `file` path, so the version can come from anywhere as long as
it matches what `tcli` stamped the ZIP with. Without a `version.txt`, a common alternative
is deriving it from the git tag. That needs a step output because `with:` values only
evaluate `${{ }}` expressions (no shell `${VAR#v}` stripping):

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Resolve version from tag
        id: version
        run: echo "value=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Build package
        run: tcli build --config-path thunderstore.toml --package-version "${{ steps.version.outputs.value }}"

      - name: Publish to Thunderstore
        env:
          TCLI_AUTH_TOKEN: ${{ secrets.TCLI_AUTH_TOKEN }}
        run: tcli publish --config-path thunderstore.toml --package-version "${{ steps.version.outputs.value }}"

      - name: Publish to Hexium
        uses: your-org/hexium-uploader@v1
        with:
          community: valheim
          file: build/YourOrg-YourMod-${{ steps.version.outputs.value }}.zip
          token: ${{ secrets.HEXIUM_API_TOKEN }}
          namespace: your-team
```

Other sources work the same way: a `workflow_dispatch` input (`${{ inputs.version }}`), or
the assembly version read from the `.csproj`.

## Notes and gotchas

- **One version per upload.** Hexium accepts each `version_number` only once; re-running on an already-published version fails at the submit step. Bump the version instead.
- **Rate limits.** Hexium enforces at most 3 uploads of the same mod per 5 minutes and 10 uploads total per 10 minutes. Single-mod releases are unaffected.
- **Icon.** `icon.png` must be exactly 256×256 (Hexium requirement).
- **Categories.** Hexium may not recognize every Thunderstore category; verify a first upload and adjust per-community categories in the web UI if needed.
