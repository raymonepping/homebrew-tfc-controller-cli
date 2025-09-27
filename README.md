# tfc_controller

[![Release](https://img.shields.io/github/v/release/raymonepping/tfc_controller)](https://github.com/raymonepping/tfc_controller/releases)
[![License](https://img.shields.io/github/license/raymonepping/tfc_controller)](./LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/raymonepping/tfc_controller/ci.yml?label=CI)](https://github.com/raymonepping/tfc_controller/actions)

---

**tfc_controller v1.0.0 — Manage & export Terraform Cloud org data**

A Bash-based controller for managing and exporting Terraform Cloud / Terraform Enterprise (TFC/TFE) organization data.
It wraps the TFC API with a consistent CLI interface and pretty-prints exports into human-readable tables.

---

## Features

* Validate org spec files
* Plan and apply org + project creation
* Export org data into JSON (minimal or full profiles)
* Pretty-print exports with filters (projects, workspaces, variables, varsets, registry, tags, users, teams)
* Gum-powered tables and styling if [`gum`](https://github.com/charmbracelet/gum) is installed
* Colorized CLI with optional `--no-color` support

---

## Installation

Clone the repo and add the `bin/` folder to your `PATH`:

```bash
git clone https://github.com/<your-org>/<repo>.git
cd <repo>
export PATH="$PWD/bin:$PATH"
```

Make sure dependencies are installed:

* `bash` (with `set -euo pipefail` support)
* `jq` ≥ 1.6
* `curl`
* [`gum`](https://github.com/charmbracelet/gum) (optional, for nice tables)

---

## Configuration

Create a `.env` file in the project root with your TFC/TFE settings:

```env
TFE_TOKEN=your-api-token
TFE_HOST=app.terraform.io   # or your TFE hostname
```

The controller will load `.env` automatically.

---

## Usage

```bash
tfc_controller <command> [options]
```

### Commands

#### validate

Validate a spec file for org creation:

```bash
tfc_controller validate spec.json
```

Requires `.org.name` and `.org.email`.

---

#### plan

Plan org + project changes:

```bash
tfc_controller plan spec.json
```

---

#### apply

Apply org + project changes:

```bash
tfc_controller apply spec.json --yes
```

---

#### ensure-org

Ensure the org exists (dry-run optional):

```bash
tfc_controller ensure-org spec.json --dry-run
```

---

#### plan-projects

Plan changes for projects only:

```bash
tfc_controller plan-projects spec.json
```

---

#### apply-projects

Apply changes for projects only:

```bash
tfc_controller apply-projects spec.json --yes
```

---

#### export

Export org data into JSON:

```bash
tfc_controller export --org my-org -o backup.json --profile full
```

Options:

* `--org <name>` — Org name
* `--spec <file>` — Spec file containing `.org.name`
* `-o, --out <file>` — Output file (required)
* `--profile` — `minimal` (default) or `full`

---

#### show

Pretty-print a prior export:

```bash
tfc_controller show --file backup.json --projects --workspaces
```

Sections:

* `--projects` — Projects
* `--workspaces` — Workspaces
* `--variables` — Workspace variables
* `--varsets` — Variable sets
* `--registry` — Registry modules
* `--tags` — Reserved tag keys
* `--users` — Users + team memberships
* `--teams` — Teams (core, memberships, project access)

Filters:

* `-p, --project "<name>"` — Filter by project
* `-w, --workspace "<name>"` — Filter by workspace
* `-t, --tag "<tag>"` — Filter by workspace tag
* `-m, --module "<name>"` — Filter by registry module

---

### Global Flags

* `-h, --help` — Show help
* `-V, --version` — Show version
* `--no-color` — Disable ANSI colors (or set `NO_COLOR=1`)

---

## Example Workflow

1. Validate org spec:

   ```bash
   tfc_controller validate spec.json
   ```

2. Plan org + projects:

   ```bash
   tfc_controller plan spec.json
   ```

3. Apply org + projects:

   ```bash
   tfc_controller apply spec.json --yes
   ```

4. Export org state:

   ```bash
   tfc_controller export --org my-org -o org_full.json --profile full
   ```

5. Show all projects and workspaces:

   ```bash
   tfc_controller show --file org_full.json --projects --workspaces
   ```

---

## Notes

* By default, `show` prints **projects + workspaces** if no section is provided.
* Use `gum` for pretty tables, otherwise output falls back to `column -t`.
* This tool is read/write safe: **validate/plan** before **apply**.

---

## Roadmap

* Add team ↔️ workspace access support
* JSON → spec roundtrip (import/export parity)
* Optional CSV export mode

---

## License

MIT © Raymon Epping