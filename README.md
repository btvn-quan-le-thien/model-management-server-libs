# Dev Team Tools

Scripts for dev team to interact with lakeFS + SeaweedFS + Auth Server,
including zstd-compressed model packing/unpacking. The scripts live at the
project root.

> `bin/lakectl` (the lakectl binary) and `.lakectl-credentials.env` (lakeFS keys)
> are gitignored — never commit them. The scripts themselves are committed.

> Want to call these from any directory instead of `./...`?
> See [Make Scripts Global](#make-scripts-global-optional) at the bottom.

## Quick Start

```bash
# 1. Server must be running first (on the server machine):
#    export SEAWEED_ACCESS_KEY=... SEAWEED_SECRET_KEY=... ADMIN_API_KEY=...
#    export LAKEFS_ACCESS_KEY_ID=... LAKEFS_SECRET_ACCESS_KEY=...
#    ./scripts/setup.sh

# 2. Run once on your dev machine: install lakectl + configure access
./dev-setup.sh

# 3. Check all services are healthy
./health.sh
```

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| lakeFS | http://localhost:8088 | Version control (repos, branches, commits, tags) |
| SeaweedFS S3 | http://localhost:9002 | Object storage (SigV4-secured; Filer UI not exposed) |
| Auth Server | http://localhost:8090 | Client downloads via API key (302 → SeaweedFS) |

---

## Pack a Model Folder (zstd + zip)

```bash
./pack.sh <folder> [options]

# Default: zstd-compress weight files (.pkl/.pt/.bin/.safetensors), then zip
./pack.sh ./model_a                         # -> ./model_a.zip

# Plain zip (skip zstd)
./pack.sh ./model_a --no-compress

# Custom extensions + zstd level
./pack.sh ./model_a -e pkl,pt -l 9

# Custom output path
./pack.sh ./model_a -o /tmp/out.zip
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--no-compress` | off | Skip zstd; produce a plain zip |
| `-e, --extensions <list>` | `pkl,pt,bin,safetensors` | Comma-separated extensions to compress (env: `PACK_EXTENSIONS`) |
| `-l, --level <1..19>` | `3` | zstd compression level |
| `-o, --output <path>` | `./<folder>.zip` | Output zip path |

What it does:
1. Copies the folder to a temp staging dir (the input is **never modified**).
2. zstd-compresses each matching file to `<name>.<ext>.zst` (original removed from the zip).
3. Zips the folder **contents** at root (so `unzip -d <dest>/` yields `<dest>/<contents>`).
4. Prints the `upload.sh` command to run next.

The `.zst` extension is self-describing: `unpack.sh` and the spatialX poller
auto-detect `*.zst` files inside the zip and decompress them. Plain zips
(`--no-compress`) round-trip correctly too — the decompress step is a no-op.

---

## Upload a Model (file or folder)

```bash
./upload.sh <file_or_folder> <repo> <branch> <version_tag>

# Upload a packed zip (typical workflow after ./pack.sh)
./pack.sh ./model_a -o ./model_a.zip
./upload.sh ./model_a.zip ml-models main v1.0.0

# Upload a single file directly
./upload.sh ./model.zip ml-models main v1.0.0

# Upload a folder (recursive)
./upload.sh ./model_a/ ml-models main v1.0.0
```

This will:
1. Upload `<path>` to `lakefs://<repo>/<branch>/<path>` (auto-detects file vs folder)
2. Commit with `version=<tag>` metadata
3. Tag the commit as `<version_tag>`

> **spatialX integration:** spatialX's lakeFS poller checks the `ml-models@main`
> commit every 1 minute. It only picks up objects ending in `.zip`. When it
> downloads a packed zip, it unzips and zstd-decompresses automatically, leaving
> the unpacked model folder at `<DefaultModelPath>/<model>/`. No manual
> decompression is needed on the spatialX side.

---

## Download a Model (file or folder)

```bash
./download.sh <repo> <ref> <path> [output_path] [--unzip|--unpack]

# Download a single file by tag
./download.sh ml-models v1.0.0 model.zip

# Download a folder by tag (recursive)
./download.sh ml-models v1.0.0 model_a/

# Download to custom path
./download.sh ml-models v1.0.0 model.zip ./downloaded.zip

# Download + plain unzip
./download.sh ml-models v1.0.0 model.zip --unzip

# Download + unpack (auto zstd-decompress via unpack.sh)
./download.sh ml-models v1.0.0 model.zip --unpack
```

`--unzip` runs a plain `unzip` (leaves `.zst` files intact). `--unpack`
delegates to `unpack.sh`, which auto-detects and decompresses `.zst` files —
use this for zips produced by `pack.sh`.

---

## Unpack a Model Zip (unzip + zstd decompress)

```bash
./unpack.sh <zip> [-d <dest_dir>] [-f]

# Default: extract to ./<basename>/ (model_a.zip -> ./model_a/)
./unpack.sh ./model_a.zip

# Custom destination
./unpack.sh ./model_a.zip -d ./restored

# Overwrite existing destination
./unpack.sh ./model_a.zip -f
```

What it does:
1. Unzips into a staging directory.
2. Detects `*.zst` files inside; if found, decompresses each with `zstd -d`
   (restoring `x.pkl.zst` → `x.pkl`, removing the `.zst`).
3. Atomically moves the staging dir to the destination.

Plain zips (no `.zst` files) are handled correctly — the decompress loop is a
no-op. Requires `unzip`; requires `zstd` only if the zip contains `.zst` files.

---

## Create a New Repo (first time only)

```bash
./lakectl.sh repo create lakefs://ml-models s3://lakefs-data/ml-models --default-branch main
```

## List Repos / Files / Tags

```bash
./lakectl.sh repo list
./lakectl.sh fs ls lakefs://ml-models/main/
./lakectl.sh tag list lakefs://ml-models
```

## Branch + Merge

```bash
./lakectl.sh branch create lakefs://ml-models/experiment -s lakefs://ml-models/main
./upload.sh ./model_v2.zip ml-models experiment v2.0.0
./lakectl.sh merge lakefs://ml-models/experiment lakefs://ml-models/main
```

## View Commit Log

```bash
./lakectl.sh log lakefs://ml-models/main
```

## Roll Back (revert a commit)

```bash
./lakectl.sh log lakefs://ml-models/main
./lakectl.sh branch revert lakefs://ml-models/main <commit-id> --yes
```

---

## Health Check

```bash
./health.sh
```

Checks lakeFS, lakeFS API, SeaweedFS S3, and Auth Server.

---

## Make Scripts Global (Optional)

By default the scripts are invoked via `./<script>.sh` from the project root.
To call them from **any directory** (e.g. `health.sh` from `/tmp`), install thin
wrapper scripts into a directory already on your `PATH`.

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
PROJECT_DIR="$(pwd)"
for name in dev-setup.sh health.sh upload.sh download.sh pack.sh unpack.sh lakectl.sh; do
  cat > "$HOME/.local/bin/$name" <<EOF
#!/bin/bash
exec ${PROJECT_DIR}/${name} "\$@"
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
# From anywhere — identical to the ./... form:
health.sh
upload.sh ./model.zip ml-models main v1.0.0
pack.sh ./model_a
unpack.sh ./model_a.zip
upload.sh ./model_a/ ml-models main v1.0.0
download.sh ml-models v1.0.0 model_a/
download.sh ml-models v1.0.0 model.zip --unzip
lakectl.sh repo list
dev-setup.sh
```

### Available global commands

| Command | Backed by |
|---------|-----------|
| `dev-setup.sh` | `dev-setup.sh` |
| `health.sh` | `health.sh` |
| `upload.sh` | `upload.sh` |
| `download.sh` | `download.sh` |
| `pack.sh` | `pack.sh` |
| `unpack.sh` | `unpack.sh` |
| `lakectl.sh` | `lakectl.sh` |

### If the project moves

The wrappers hardcode the absolute path of the real scripts. After moving the
project, re-run the **Setup** block above from the new project root to
overwrite the wrappers with the updated path.

---

## File Reference

| Script | Description |
|--------|-------------|
| `dev-setup.sh` | Install lakectl + configure access (run once) |
| `pack.sh` | Pack a model folder: zstd-compress weights, then zip |
| `upload.sh` | Upload file or folder + commit + tag |
| `download.sh` | Download file or folder via lakectl (optional: `--unzip`/`--unpack`) |
| `unpack.sh` | Unpack a zip: unzip + auto zstd-decompress `.zst` files |
| `health.sh` | Check lakeFS + SeaweedFS + Auth Server |
| `lakectl.sh` | Raw lakectl access (for advanced operations) |
| `bin/lakectl` | lakectl binary (downloaded by `dev-setup.sh`, gitignored) |

---

## Complete Workflow Example

```bash
# 1. First time: install lakectl
./dev-setup.sh

# 2. Create repo (first time only)
./lakectl.sh repo create lakefs://ml-models s3://lakefs-data/ml-models --default-branch main

# 3. Pack a model folder (zstd-compress weights -> zip)
./pack.sh ./model_a -o ./model_a.zip

# 4. Upload the packed zip, commit, tag
./upload.sh ./model_a.zip ml-models main v1.0.0

# 5. Download the zip by tag
./download.sh ml-models v1.0.0 model_a.zip

# 6. Unpack (unzip + auto zstd-decompress)
./unpack.sh ./model_a.zip

# Or combine download + unpack in one step:
./download.sh ml-models v1.0.0 model_a.zip --unpack
```
