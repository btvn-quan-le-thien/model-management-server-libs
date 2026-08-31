# unit_test/ — Dev Team Script Test Suite

Bash test suite for the dev-team scripts: **pack.sh**, **unpack.sh**,
**upload.sh**, **download.sh**, plus **dev-setup.sh** credential validation
and a **500 MB big-upload** test. Verifies zstd compression, size reduction,
pack/unpack round-trips, credential security, and the full upload → download
lakeFS round-trip (including large files).

## Files

| File | What it tests |
|------|---------------|
| `common.sh` | Shared helpers: colored pass/fail, assertions, fixture builders (small + 500 MB), lakeFS helpers, lakectl config generator, per-run repo lifecycle. *Sourced, not run directly.* |
| `test_pack.sh` | `pack.sh` — pack **with zstd** (weights → `*.zst`, size reduced vs original folder and vs plain zip) and **without zstd** (`--no-compress`, raw weights, no `.zst`). Also checks the source folder is left untouched. |
| `test_unpack.sh` | `pack.sh` → `unpack.sh` round-trip **with zstd** and **without zstd**, asserting `diff -r` of the restored folder equals the original. Plus the `-f` force guard (refuse without `-f`, overwrite with `-f`). |
| `test_credentials.sh` | `dev-setup.sh` credential validation: **no credentials** (file missing → dev-setup.sh fails), **empty credentials** (→ 401), **correct credentials** (→ repo list succeeds), **brute force** (100 wrong-credential attempts → all 401 rejected). Uses temp lakectl configs so `~/.lakectl.yaml` is never touched. |
| `test_upload.sh` | `upload.sh` against lakeFS. Creates a per-run repo if missing, uploads a zip + a folder, and verifies the object is listed, the commit carries `version=<tag>` metadata, and the tag exists. `--no-cleanup` keeps the repo. |
| `test_download.sh` | `download.sh` against lakeFS. Self-provisions (packs + uploads under a download-specific tag) then: file download → **byte-exact sha256**; `--unzip` → leaves `.zst`; `--unpack` → auto zstd-decompress + `diff -r` == original; folder download (recursive) → contents match. |
| `test_big_upload.sh` | **500 MB big upload**: spawns a ~500 MB realistic model folder (`model.pkl`/`weights.pt`/`vocab.bin` + metadata, using a repeated random block), packs with zstd → `model_big_a.zip` (~50 MB) and without → `model_big_a_no_compress.zip` (~500 MB), asserts **zstd zip < no-compress zip** (~90% reduction), uploads both to lakeFS (both visible as large objects), verifies objects + tags, and downloads back for **sha256 byte-exact** verification. `--no-cleanup` keeps the repo. |
| `run_all.sh` | Orchestrator. Runs all suites in order, gates lakeFS via `health.sh`, deletes the per-run repo at the end (unless `--no-cleanup`), prints a pass/fail/skip summary, exits non-zero on any failure. |
| `README.md` | This file. |

## Quick start

```bash
# From the project root (lakeFS must be running + ./dev-setup.sh done):
./unit_test/run_all.sh

# Keep the test repo for manual inspection afterwards:
./unit_test/run_all.sh --no-cleanup

# Run a single suite:
./unit_test/test_pack.sh
./unit_test/test_unpack.sh
./unit_test/test_credentials.sh
./unit_test/test_upload.sh
./unit_test/test_download.sh
./unit_test/test_big_upload.sh        # 500 MB upload test (~30s)

# Skip the lakeFS-dependent suites (e.g. server down), still run local tests:
SKIP_LAKEFS=1 ./unit_test/run_all.sh

# Customize brute-force attempt count (default 100):
BRUTE_COUNT=50 ./unit_test/test_credentials.sh

# Customize big upload size (default 500 MB):
BIG_SIZE_MB=200 ./unit_test/test_big_upload.sh
```

## Prerequisites

- `zip`, `unzip`, `zstd` on `PATH` (the scripts themselves require these).
- lakeFS running locally + `./dev-setup.sh` completed (for `test_upload.sh` /
  `test_download.sh` / `test_big_upload.sh` / the lakeFS parts of
  `test_credentials.sh`). The local tests (`test_pack.sh`, `test_unpack.sh`,
  and the "no credentials" part of `test_credentials.sh`) need **no** lakeFS.
- A dedicated test repo is created automatically per run (see **Repo lifecycle**
  below) and deleted at the end of `run_all.sh`.

## What each suite verifies

### test_pack.sh
1. **With zstd (default):** `model.pkl`/`weights.pt`/`vocab.bin` appear as
   `*.zst` inside the zip; `config.json`/`README.md` stay uncompressed; the zip
   is **smaller than the original folder** and **smaller than the `--no-compress` zip**.
2. **Without zstd (`--no-compress`):** raw weight files present, no `.zst`.
3. The source folder is not modified (pack stages a copy).

### test_unpack.sh
1. **With zstd:** pack → unpack → `diff -r restored == original` (`.zst` decompressed back).
2. **Without zstd:** same round-trip.
3. **Force guard:** unpack into an existing dir fails without `-f`, succeeds with `-f`.

### test_credentials.sh
1. **No credentials (file missing):** `dev-setup.sh` copied to a temp dir without
   `config.env` → must fail with "Credentials file not found".
2. **Empty credentials (credential is "none"):** a lakectl config with empty
   `access_key_id`/`secret_access_key` → must be rejected with **401 Unauthorized**.
3. **Correct credentials:** a lakectl config built from the real
   `config.env` → `lakectl repo list` succeeds and returns repos.
4. **Brute force (100 attempts):** 100 different wrong credential pairs, each
   running `lakectl repo list` via a temp config file (`-c <file>`). Every attempt
   must be rejected (401). Asserts `100/100 rejected, 0/100 breached`. Configurable
   via `BRUTE_COUNT=<n>`.
   - **Safety:** all tests use `lakectl -c <temp_file>`, so the real
     `~/.lakectl.yaml` is never modified.

### test_upload.sh
- Creates a per-run repo `lakefs://unit-test-<runid>` if it doesn't exist.
- Uploads a packed zip to `unit-test-<runid>@main` with tag `unit-test-<runid>`;
  verifies the object is listed, the commit log shows `version = <tag>`, and the
  tag exists.
- Uploads the fixture folder with tag `unit-test-<runid>-folder`; verifies the
  folder contents are visible.

### test_download.sh
- Self-provisions: packs + uploads its own fixture (`model_test_dl.*`, distinct
  object paths so it never collides with `test_upload.sh`'s uploads on the same
  branch) under tag `unit-test-<runid>-dl`.
- **File download:** downloaded zip sha256 == uploaded zip sha256; a second
  download is byte-identical (deterministic).
- **`--unzip`:** plain unzip leaves `model.pkl.zst` (no decompression).
- **`--unpack`:** `unpack.sh` auto-decompresses; restored folder `diff -r` == original.
- **Folder download:** recursive download contents == original fixture.

### test_big_upload.sh
- Spawns a ~500 MB realistic model folder with the same structure pack.sh
  expects: `config.json`, `README.md` (plain), and three weight files —
  `model.pkl` (40%), `weights.pt` (40%), `vocab.bin` (20%) — filled with a 1 MiB
  random block repeated many times.
- This data has a key property: **zstd's large window finds the repeats and
  compresses dramatically (~90%), while zip deflate's small window (~32 KB)
  can't see across the block boundary and stores nearly as-is.** So:
  - `model_big_a.zip` (zstd) ≈ 50 MB — dramatic reduction, still a substantial file.
  - `model_big_a_no_compress.zip` (no-compress) ≈ 500 MB — genuinely large in lakeFS.
- Asserts **zstd zip < no-compress zip** (~90% reduction).
- Uploads both to the per-run repo; verifies each object is listed and the tag
  exists. Both files are visible as large objects in lakeFS.
- **Download + sha256 verify:** downloads `model_big_a.zip` back and asserts
  byte-exact sha256 match (big-file round-trip through lakeFS).
- `BIG_SIZE_MB=<n>` env var adjusts the fixture size (default 500).

## Repo lifecycle / cleanup

- `run_all.sh` exports a shared `UNIT_TEST_RUN_ID` so upload/download agree on the
  repo name and tags.
- **Per-run repo:** the repo is named `unit-test-<runid>` with storage namespace
  `s3://lakefs-data/unit-test-<runid>`. Two reasons:
  1. lakeFS rejects underscores in repo names (hence the hyphen), and
  2. deleting a lakeFS repo leaves its storage namespace permanently "dirty"
     (a `_lakefs/dummy` marker), so a fixed name could not be recreated across
     runs. A per-run namespace avoids that collision entirely, making the suite
     safely re-runnable.
- `run_all.sh` invokes `test_upload.sh --no-cleanup` and
  `test_big_upload.sh --no-cleanup` (so the repo survives for the download
  tests), then **deletes the per-run repo after all lakeFS tests finish**
  (unless you pass `--no-cleanup`).
- `SKIP_LAKEFS=1` skips the lakeFS suites while still running the local
  pack/unpack/credentials tests.
- Standalone `test_upload.sh` / `test_big_upload.sh` deletes the repo at their
  own end unless `--no-cleanup`.
- Standalone `test_download.sh` creates its own repo and **leaves it** (run it via
  `run_all.sh`, or delete manually: `./lakectl.sh repo delete lakefs://unit-test-<runid> -y`).
  It self-provisions, so it does not depend on `test_upload.sh` having run.

## Output

Each suite prints `[PASS]`/`[FAIL]` lines and a per-suite summary
(`PASS: X  FAIL: Y  SKIP: Z`). `run_all.sh` prints an overall table and total
counts, and exits non-zero if any suite failed.

## Notes

- No script under test is modified; all tests run in `mktemp -d` work dirs that
  are cleaned up on exit.
- Small fixture weight files are 5 MiB of a repeated byte pattern — compresses
  dramatically under zstd so the size-reduction assertion is unambiguous, while
  staying fast to generate.
- Big fixture (500 MB) mirrors a real model: `config.json`, `README.md`, and
  three weight files (`model.pkl` 40%, `weights.pt` 40%, `vocab.bin` 20%) using a
  1 MiB random block repeated many times. zstd's large window compresses this
  ~90% (→ ~50 MB zip), while zip deflate can't (→ ~500 MB zip). Both files are
  genuinely large in lakeFS, and the reduction is dramatic. Configurable via
  `BIG_SIZE_MB`. Requires `dd` + `/dev/urandom`.
- Credential brute-force test uses 100 attempts by default (`BRUTE_COUNT=<n>`
  to change). Each attempt runs `lakectl -c <temp_config> repo list` — total
  ~2–3s for 100 attempts.
- Tags and repo names are timestamp-based and unique per run, so the suite is
  safely re-runnable.
- Deleting a repo leaves orphaned objects in SeaweedFS under the (unique)
  per-run namespace; they don't affect future runs. Wipe SeaweedFS storage if
  you want to reclaim that space.
