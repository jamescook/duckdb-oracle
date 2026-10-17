# Self-hosted runner for the real-Oracle end-to-end tests

The workflow [`e2e-oracle19c.yml`](../.github/workflows/e2e-oracle19c.yml) runs the SQL tests in [`test/e2e`](../test/e2e)
against a **real Oracle 19c database on your own Windows machine**. GitHub's hosted runners have no Oracle, so this job
runs on a *self-hosted runner* that you register once. This page is for the repository owner.

What it does, in order: checks the runner's configuration, optionally starts a Docker container, takes the `windows_amd64`
build from the latest successful `ci.yml` run on `main`, downloads the official DuckDB CLI (checksum verified), checks that a
64-bit `oci.dll` is first on `PATH`, loads the extension, waits up to 5 minutes for the database, and runs every
`test/e2e/*.sql` through [`test-windows.ps1`](../test-windows.ps1) (`-Strict`). Run the same script by hand to get the same result
locally.

## What the machine needs

* Windows x64 with Windows PowerShell 5.1 (every supported Windows has it). No Zig and no Python are needed: the extension
  comes from CI.
* **64-bit Oracle Instant Client** (Basic) with its directory on the **machine** `PATH` (see
  [step 3](#3-let-the-service-see-instant-client)), and the Microsoft Visual C++ Redistributable (x64).
* Network access to `github.com` (runner, artifact and DuckDB CLI downloads) and to the database.
* Docker only if the database container runs on this machine and you want the workflow to start it.
* An Oracle account that can connect (`CREATE SESSION`). The tests only select from `DUAL`, and an optional test reads `V$VERSION`
  (a warning, not a failure, if the account cannot). Use a low-privilege account on a database with nothing important in it.

## 1. Register the runner (label `oracle19c`)

In the repository: **Settings > Actions > Runners > New self-hosted runner > Windows x64**. That page shows the current download
commands and a one-time registration token; use them. In an **administrator** PowerShell it looks like this
(version numbers and the token come from that page):

```powershell
mkdir C:\actions-runner; cd C:\actions-runner
# download and unzip the runner exactly as the Settings page shows, then:
.\config.cmd --url https://github.com/jamescook/duckdb-oracle --token <TOKEN-FROM-THE-PAGE> `
    --name oracle19c-windows --labels oracle19c --runasservice
```

* `--labels oracle19c` adds the label the workflow asks for. `self-hosted`, `windows` and `X64` are added automatically, so the
  workflow's `runs-on: [self-hosted, windows, oracle19c]` matches only this machine.
* `--runasservice` installs it as a Windows service that starts at boot, so no one has to stay logged in. `config.cmd` asks which
  account the service runs as (`.\config.cmd --help` lists the non-interactive options). Do not accept the default
  `NT AUTHORITY\NETWORK SERVICE` blindly: it has had trouble reading runner folders under a user profile (hence `C:\actions-runner`
  above), and if the workflow starts a container the account must be allowed to use Docker (a member of `docker-users`). A normal
  user account that owns `C:\actions-runner` is the simplest choice.
* Check it: **Settings > Actions > Runners** should show `oracle19c-windows` as *Idle*. In PowerShell:
  `Get-Service 'actions.runner.*'`.

To remove it later: `.\config.cmd remove --token <TOKEN>` (a fresh token from the same page).

## 2. Tell the runner about the database: the `.env` file

The database address and login name are **not** in the repository. They come from a file named `.env` in the runner folder
(`C:\actions-runner\.env`), one `KEY=VALUE` per line, with no quotes and no `export`:

```
ORACLE_DSN=localhost:1521/ORCLPDB1
ORACLE_USER=SAMPLE_DEV
ORACLE_CONTAINER=oracle19c
```

| Key | Required | Meaning |
|---|---|---|
| `ORACLE_DSN` | yes | Easy Connect string `host:port/service_name` of the 19c database, as this machine reaches it |
| `ORACLE_USER` | yes | the Oracle user the tests log in as |
| `ORACLE_CONTAINER` | no | name of a Docker container to `docker start` before the tests. Leave it out if the database is not a container on this machine. The workflow only ever runs `docker start`: it never pulls an image and never logs in to a registry |

The password is **not** here. It is the repository secret `ORACLE_PASSWORD` (see [below](#4-set-the-oracle_password-secret)).

The runner reads `.env` only when it starts, so **restart the service after every change**:

```powershell
Restart-Service 'actions.runner.*'
```

If `ORACLE_DSN` or `ORACLE_USER` is missing, the first step of the job fails immediately and says which one. Because job logs of a
public repository are public, the first step masks both values (`::add-mask::`), so the log shows `***` instead of your database
address and account name, in every step of the job.

### The database is not on this machine (for example a Windows VM on a Mac)

If Windows runs in a virtual machine (Parallels, UTM, VMware Fusion, ...) and the Oracle container runs in Docker on the **Mac host**,
the database is *not* at `localhost` from the VM's point of view:

* Set `ORACLE_DSN` to an address **of the Mac that the VM can reach**: `ORACLE_DSN=<mac-ip>:1521/ORCLPDB1`. The simplest one is the
  Mac's ordinary network address (`ipconfig getifaddr en0` in a Mac terminal for Wi-Fi or Ethernet). It changes if the router hands
  out a new lease, so give the Mac a DHCP reservation. Virtual networks also give the Mac an address of its own: on Parallels'
  *Shared* network it is `10.211.55.2`. Do **not** use the VM's *Default Gateway* from `ipconfig` without checking it: on Parallels
  the gateway (`10.211.55.1`) is the virtual router, not the Mac. UTM, VMware Fusion and others use different numbers; see their
  network documentation.
* **Leave `ORACLE_CONTAINER` out.** There is no Docker inside the VM, so the workflow cannot start the container. Start it on the Mac
  yourself (`docker start <name>`) before running the workflow; the 5-minute wait for the database covers its start-up.
* On the Mac, the container must publish the port (`-p 1521:1521`) and the macOS firewall must allow incoming connections to Docker.
* Check from the VM before you try the workflow: `Test-NetConnection <mac-ip> -Port 1521` should report `TcpTestSucceeded : True`.

## 3. Let the service see Instant Client

A Windows service gets the **machine** `PATH`, not your user's. Add the 64-bit Instant Client directory (for example
`C:\oracle\instantclient_19_26`) to the machine `PATH` (System Properties > Environment Variables > *System variables*), and put it
**before** any 32-bit client. Then restart the service. If the runner was configured before you changed `PATH`, it may keep an older
`PATH` in a `.path` file in the runner folder; edit or delete that file, then restart the service.

The job's `-Strict` check fails with a clear message if the first `oci.dll` it finds is 32-bit or if none is found.

## 4. Set the `ORACLE_PASSWORD` secret

**Settings > Secrets and variables > Actions > New repository secret**, name `ORACLE_PASSWORD`, value the Oracle user's password.
Or with the GitHub CLI, which asks for the value without echoing it:

```sh
gh secret set ORACLE_PASSWORD --repo jamescook/duckdb-oracle
```

The password reaches the test process only as an environment variable. It is never placed on a command line or in SQL text; GitHub
masks it in logs; and `test-windows.ps1` additionally removes it from any output and **fails the run if a test's output ever
contains it**.

## 5. Run it

The workflow has no automatic triggers. The workflow file must be on the default branch first; then:

* in the browser: **Actions > "E2E Oracle 19c (self-hosted)" > Run workflow** (branch `main`); or
* from a terminal: `gh workflow run e2e-oracle19c.yml --repo jamescook/duckdb-oracle --ref main`, then
  `gh run watch --repo jamescook/duckdb-oracle`.

It tests the **latest successful `ci.yml` build on `main`**. If you have just pushed, wait for `ci.yml` to finish and pass first,
or the job tells you there is no build to test. The tests and scripts come from the branch you dispatch, so for a normal run
use `main`.

Only a build of a commit that is **on `main`**, from a **push to this repository**, can be chosen. That matters because the build is
loaded into `duckdb.exe` on your machine while the database password is in its environment. A pull request from a fork whose branch
happens to be called `main` has `ci.yml` runs and artifacts too, and a plain "branch is main" lookup would match them; the workflow
therefore asks for push events only, re-checks the event and the repository of every run, and asks GitHub whether the built commit
is an ancestor of `main`.

To run the same tests by hand on this machine (with a checkout, `$env:ORACLE_DSN` / `$env:ORACLE_USER` set, and the password
entered without echo, see `Get-Help .\test-windows.ps1 -Full`):

```powershell
.\test-windows.ps1 -Extension .\duckdb_oracle-windows_amd64.zip -Strict -WaitForDatabase 300
```

## Why it is manual-only and owner-locked

A self-hosted runner executes whatever the workflow file says, **on your own computer, with network access to your database**. On a
public repository anyone can open a pull request that changes a workflow, so a runner must never react to pull requests. Therefore:

* the only trigger is `workflow_dispatch`, which needs write access to start. There is no `push` and no `pull_request` trigger;
* the job runs only `if: github.actor == 'jamescook' && github.repository_owner == 'jamescook'`, so even someone else with write
  access cannot start it on your machine;
* the password is a repository secret and is never available to pull requests from forks;
* only one run happens at a time (`concurrency`), because they share one database.

Further hardening that is worth doing in the repository settings: under **Settings > Actions > General**, set the option for
workflow runs from fork pull requests to its strictest choice (approval required for all outside contributors; GitHub renames
this option from time to time), keep the runner registered to this repository only, and keep the database account
low-privilege.
