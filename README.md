# scripts-local — Dev Team Tools

Scripts for dev team to interact with lakeFS + SeaweedFS + Auth Server.
Gitignored — not committed to the repo.

> Want to call these from any directory instead of `./scripts-local/...`?
> See [Make Scripts Global](#make-scripts-global-optional) at the bottom.

## Quick Start

```bash
# 1. Server must be running first (on the server machine):
#    export SEAWEED_ACCESS_KEY=... SEAWEED_SECRET_KEY=... ADMIN_API_KEY=...
#    export LAKEFS_ACCESS_KEY_ID=... LAKEFS_SECRET_ACCESS_KEY=...
#    ./scripts/setup.sh

# 2. Run once on your dev machine: install lakectl + configure access
./scripts-local/dev-setup.sh

# 3. Check all services are healthy
./scripts-local/health.sh
```

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| lakeFS | http://localhost:8088 | Version control (repos, branches, commits, tags) |
| SeaweedFS S3 | http://localhost:9002 | Object storage (SigV4-secured; Filer UI not exposed) |
| Auth Server | http://localhost:8090 | Client downloads via API key (302 → SeaweedFS) |

---

## Upload a Model (file or folder)

```bash
./scripts-local/upload.sh <file_or_folder> <repo> <branch> <version_tag>

# Upload a single file, commit, tag as v1.0.0
./scripts-local/upload.sh ./model.zip ml-models main v1.0.0

# Upload a folder (recursive)
./scripts-local/upload.sh ./model_a/ ml-models main v1.0.0
```

This will:
1. Upload `<path>` to `lakefs://<repo>/<branch>/<path>` (auto-detects file vs folder)
2. Commit with `version=<tag>` metadata
3. Tag the commit as `<version_tag>`

---

## Download a Model (file or folder)

```bash
./scripts-local/download.sh <repo> <ref> <path> [output_path] [--unzip]

# Download a single file by tag
./scripts-local/download.sh ml-models v1.0.0 model.zip

# Download a folder by tag (recursive)
./scripts-local/download.sh ml-models v1.0.0 model_a/

# Download to custom path
./scripts-local/download.sh ml-models v1.0.0 model.zip ./downloaded.zip

# Download + auto-unzip
./scripts-local/download.sh ml-models v1.0.0 model.zip --unzip
```

---

## Create a New Repo (first time only)

```bash
./scripts-local/lakectl.sh repo create lakefs://ml-models s3://lakefs-data/ml-models --default-branch main
```

## List Repos / Files / Tags

```bash
./scripts-local/lakectl.sh repo list
./scripts-local/lakectl.sh fs ls lakefs://ml-models/main/
./scripts-local/lakectl.sh tag list lakefs://ml-models
```

## Branch + Merge

```bash
./scripts-local/lakectl.sh branch create lakefs://ml-models/experiment -s lakefs://ml-models/main
./scripts-local/upload.sh ./model_v2.zip ml-models experiment v2.0.0
./scripts-local/lakectl.sh merge lakefs://ml-models/experiment lakefs://ml-models/main
```

## View Commit Log

```bash
./scripts-local/lakectl.sh log lakefs://ml-models/main
```

## Roll Back (revert a commit)

```bash
./scripts-local/lakectl.sh log lakefs://ml-models/main
./scripts-local/lakectl.sh branch revert lakefs://ml-models/main <commit-id> --yes
```

---

## Health Check

```bash
./scripts-local/health.sh
```

Checks lakeFS, lakeFS API, SeaweedFS S3, and Auth Server.

---

## Make Scripts Global (Optional)

By default the scripts are invoked via `./scripts-local/<script>.sh` from the
project root. To call them from **any directory** (e.g. `health.sh` from `/tmp`),
install thin wrapper scripts into a directory already on your `PATH`.

### Why wrappers (not symlinks)

All scripts locate sibling files relative to their own path using
`SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`. A symlink would set `SCRIPT_DIR`
to the symlink's directory (e.g. `~/.local/bin`), breaking lookups for
`bin/lakectl`, `lakectl.sh`, and `.lakectl-credentials.env`. A wrapper that
`exec`s the real script by absolute path keeps `$0` pointing at the real
script, so `SCRIPT_DIR` resolves correctly.

### Setup

`~/.local/bin` is already on `PATH` on most systems. Create one wrapper per
script:

```bash
# From the project root:
SCRIPTS_DIR="$(cd scripts-local && pwd)"
for name in dev-setup.sh health.sh upload.sh download.sh lakectl.sh; do
  cat > "$HOME/.local/bin/$name" <<EOF
#!/bin/bash
exec ${SCRIPTS_DIR}/${name} "\$@"
EOF
  chmod +x "$HOME/.local/bin/$name"
done
```

### Verify

```bash
cd /tmp && command -v health.sh && health.sh
```

### Usage after setup

```bash
# From anywhere — identical to the ./scripts-local/... form:
health.sh
upload.sh ./model.zip ml-models main v1.0.0
upload.sh ./model_a/ ml-models main v1.0.0
download.sh ml-models v1.0.0 model_a/
download.sh ml-models v1.0.0 model.zip --unzip
lakectl.sh repo list
dev-setup.sh
```

### Available global commands

| Command | Backed by |
|---------|-----------|
| `dev-setup.sh` | `scripts-local/dev-setup.sh` |
| `health.sh` | `scripts-local/health.sh` |
| `upload.sh` | `scripts-local/upload.sh` |
| `download.sh` | `scripts-local/download.sh` |
| `lakectl.sh` | `scripts-local/lakectl.sh` |

### If the project moves

The wrappers hardcode the absolute path of the real scripts. After moving the
project, re-run the **Setup** block above from the new project root to
overwrite the wrappers with the updated path.

---

## File Reference

| Script | Description |
|--------|-------------|
| `dev-setup.sh` | Install lakectl + configure access (run once) |
| `upload.sh` | Upload file or folder + commit + tag |
| `download.sh` | Download file or folder via lakectl (optional: `--unzip`) |
| `health.sh` | Check lakeFS + SeaweedFS + Auth Server |
| `lakectl.sh` | Raw lakectl access (for advanced operations) |
| `bin/lakectl` | lakectl binary (downloaded by `dev-setup.sh`) |

---

## Complete Workflow Example

```bash
# 1. First time: install lakectl
./scripts-local/dev-setup.sh

# 2. Create repo (first time only)
./scripts-local/lakectl.sh repo create lakefs://ml-models s3://lakefs-data/ml-models --default-branch main

# 3. Upload model folder
./scripts-local/upload.sh ./model_a/ ml-models main v1.0.0

# 4. Download model folder (by tag)
./scripts-local/download.sh ml-models v1.0.0 model_a/

# 5. Download single file + unzip
./scripts-local/download.sh ml-models v1.0.0 model.zip --unzip
```
