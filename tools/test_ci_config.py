#!/usr/bin/env python3
"""Guards the contract of the CI setup (python3 -m unittest discover -s tools).

Workflows are code that nobody runs until it matters, and the rules here are the ones whose breakage is expensive:
a self-hosted runner reacting to a pull request, a password reaching a log, a DuckDB version defined in two places,
a platform that is built but never uploaded. Each test names the rule it protects.
"""
import glob
import json
import os
import re
import unittest

try:
    import yaml
except ImportError:  # the checks need a YAML parser; report a skip rather than a false failure
    yaml = None

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WORKFLOWS = os.path.join(REPO, ".github", "workflows")
COMPOSITE = os.path.join(REPO, ".github", "actions", "build-test", "action.yml")


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return f.read()


def load(path):
    return yaml.safe_load(read(path))


def triggers(doc):
    on = doc.get("on", doc.get(True))  # PyYAML (YAML 1.1) turns the key `on` into the boolean True
    return set(on) if isinstance(on, dict) else ({on} if isinstance(on, str) else set(on))


def run_blocks(doc):
    for job in doc["jobs"].values():
        for step in job.get("steps", []):
            if "run" in step:
                yield step.get("name", "(unnamed)"), step["run"]


class Environment(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("GITHUB_ACTIONS"), "enforced on CI only; locally a missing PyYAML just skips the checks")
    def test_pyyaml_is_installed_on_ci_so_the_workflow_checks_cannot_be_skipped(self):
        self.assertIsNotNone(yaml, "install PyYAML in the CI step that runs these tests")


@unittest.skipUnless(yaml, "PyYAML is not installed")
class WorkflowContract(unittest.TestCase):
    def wf(self, name):
        return load(os.path.join(WORKFLOWS, name))

    def test_exactly_these_four_workflows_exist(self):
        found = sorted(os.path.basename(p) for p in glob.glob(os.path.join(WORKFLOWS, "*.y*ml")))
        self.assertEqual(found, ["ci.yml", "e2e-oracle19c.yml", "windows.yml", "zig-0.15.yml"])

    def test_ci_is_automatic_and_the_others_are_manual(self):
        self.assertEqual(triggers(self.wf("ci.yml")), {"push", "pull_request", "workflow_dispatch"})
        for name in ("zig-0.15.yml", "windows.yml", "e2e-oracle19c.yml"):
            self.assertEqual(triggers(self.wf(name)), {"workflow_dispatch"}, name)

    def test_ci_uses_zig_0_17_only_and_the_015_workflow_uses_0_15_2(self):
        ci = self.wf("ci.yml")["jobs"]["build-test"]
        self.assertEqual(ci["runs-on"], "ubuntu-latest")
        uses = [s for s in ci["steps"] if s.get("uses") == "./.github/actions/build-test"]
        self.assertEqual([u["with"]["zig-version"] for u in uses], ["0.17.0"])
        self.assertEqual(uses[0]["with"]["upload-artifacts"], "true")
        old = self.wf("zig-0.15.yml")["jobs"]["build-test"]
        self.assertEqual(old["runs-on"], "ubuntu-latest")
        uses = [s for s in old["steps"] if s.get("uses") == "./.github/actions/build-test"]
        self.assertEqual([u["with"]["zig-version"] for u in uses], ["0.15.2"])
        self.assertEqual(uses[0]["with"]["upload-artifacts"], "false")

    def test_ci_runs_the_hosted_oracle_e2e_on_free_23ai_and_xe_21c(self):
        job = self.wf("ci.yml")["jobs"]["e2e-oracle"]
        self.assertEqual(job["runs-on"], "ubuntu-latest")
        self.assertEqual(job["needs"], "build-test", "it tests the artifact the build job made")
        images = {m["image"]: m for m in job["strategy"]["matrix"]["include"]}
        self.assertEqual(sorted(images), ["gvenzl/oracle-free:23-slim", "gvenzl/oracle-xe:21-slim"])
        self.assertEqual(images["gvenzl/oracle-free:23-slim"]["service"], "FREEPDB1")
        self.assertEqual(images["gvenzl/oracle-xe:21-slim"]["service"], "XEPDB1")
        free_dirs = images["gvenzl/oracle-free:23-slim"]["dirs"].split()
        xe_dirs = images["gvenzl/oracle-xe:21-slim"]["dirs"].split()
        self.assertIn("test/e2e/spatial", free_dirs)
        self.assertIn("test/e2e/spatial", xe_dirs)
        self.assertIn("test/e2e/23ai", free_dirs, "VECTOR and BOOLEAN need 23ai")
        self.assertIn("test/e2e/needs-setup/23ai", free_dirs, "the tests that need the setup scripts run after them")
        self.assertNotIn("test/e2e/23ai", xe_dirs, "XE 21c has no VECTOR or BOOLEAN")
        self.assertNotIn("test/e2e/needs-setup/23ai", xe_dirs)
        for image in images.values():
            # the schema tests and the setup they need run on both databases, the setup before the tests
            self.assertIn("test/e2e/needs-setup/schema", image["dirs"].split(), image["image"])
            self.assertEqual(image["setup"].split()[0], "test/e2e/setup/common", image["image"])
        self.assertIn("test/e2e/setup/23ai", images["gvenzl/oracle-free:23-slim"]["setup"].split())
        self.assertNotIn("test/e2e/setup/23ai", images["gvenzl/oracle-xe:21-slim"]["setup"].split())
        self.assertEqual(job["services"]["oracle"]["image"], "${{ matrix.image }}")
        self.assertIn("healthcheck.sh", job["services"]["oracle"]["options"])
        text = "\n".join(r for _, r in run_blocks({"jobs": {"e2e-oracle": job}}))
        self.assertIn("tools/fetch-duckdb-cli.sh linux-amd64", text, "the pinned CLI, never whatever is on PATH")
        self.assertIn("tools/e2e_run.py", text)
        self.assertRegex(text, r"--wait\s+300")
        self.assertNotRegex(text, r"docker (pull|login)")
        download = [s for s in job["steps"] if str(s.get("uses", "")).startswith("actions/download-artifact")]
        self.assertEqual(download[0]["with"]["name"], "duckdb_oracle-linux_amd64")

    def test_windows_workflow_runs_on_windows_latest_with_both_zig_versions(self):
        job = self.wf("windows.yml")["jobs"]["windows"]
        self.assertEqual(job["runs-on"], "windows-latest")
        self.assertEqual(sorted(job["strategy"]["matrix"]["zig"]), ["0.15.2", "0.17.0"])
        text = "\n".join(r for _, r in run_blocks(self.wf("windows.yml")))
        self.assertIn("test-windows.ps1", text)

    # ---- the self-hosted job ----------------------------------------------------------
    def test_e2e_job_is_locked_to_the_owner_and_to_the_labelled_runner(self):
        job = self.wf("e2e-oracle19c.yml")["jobs"]["e2e"]
        self.assertEqual(job["runs-on"], ["self-hosted", "windows", "oracle19c"])
        guard = job["if"]
        self.assertIn("github.actor == 'jamescook'", guard)
        self.assertIn("github.repository_owner == 'jamescook'", guard)

    def test_e2e_only_ever_does_docker_start(self):
        text = read(WORKFLOWS, "e2e-oracle19c.yml")
        for forbidden in ("docker pull", "docker login", "docker run", "docker build", "docker compose", "docker-compose"):
            self.assertNotIn(forbidden, text)
        self.assertIn("docker start", text)

    def test_the_password_only_travels_as_an_environment_variable(self):
        doc = self.wf("e2e-oracle19c.yml")
        # 1) the secret is referenced only inside `env:` mappings, never inside a script body or an argument
        for name, script in run_blocks(doc):
            self.assertNotIn("secrets.", script, name)
            for line in script.splitlines():
                # naming the secret in an error message is fine; reading, assigning or expanding its value is not
                if re.search(r"\$\{?env:ORACLE_PASSWORD(?!_IS_SET)|%ORACLE_PASSWORD%|\bORACLE_PASSWORD\s*=|\$ORACLE_PASSWORD", line):
                    self.fail(f"step '{name}' uses the password's value in its script: {line.strip()}")
        for job in doc["jobs"].values():
            for step in job["steps"]:
                for key, value in step.items():
                    if key == "env" or "secrets.ORACLE_PASSWORD" not in str(value):
                        continue
                    self.fail(f"secret used outside env: {key}: {value}")
        # 2) which steps see it: only the presence flag and the test step
        holders = [s.get("name") for s in doc["jobs"]["e2e"]["steps"] if "secrets.ORACLE_PASSWORD" in str(s.get("env", {}))]
        self.assertEqual(len(holders), 2, holders)
        # 3) no step turns shell tracing on, which would print every command with its environment
        for name, script in run_blocks(doc):
            self.assertNotRegex(script, r"Set-PSDebug|set -x|Get-ChildItem env:|\bdir env:|\$env:\s*\|", name)

    def test_expressions_never_appear_inside_a_script_body(self):
        # `${{ ... }}` inside run: is pasted into the script before it runs: the classic injection route. Values go through env:.
        for path in glob.glob(os.path.join(WORKFLOWS, "*.yml")) + [COMPOSITE]:
            doc = load(path)
            jobs = doc["jobs"].values() if "jobs" in doc else [{"steps": doc["runs"]["steps"]}]
            for job in jobs:
                for step in job["steps"]:
                    if "run" in step:
                        self.assertNotIn("${{", step["run"], f"{os.path.basename(path)}: {step.get('name')}")

    def test_e2e_keeps_the_database_address_and_account_out_of_the_public_log(self):
        first = next(r for n, r in run_blocks(self.wf("e2e-oracle19c.yml")) if n == "Check the runner configuration and the secret")
        self.assertIn("'::add-mask::' + $env:ORACLE_DSN", first)
        self.assertIn("'::add-mask::' + $env:ORACLE_USER", first)
        self.assertNotRegex(first, r"Write-Host \(?'ORACLE_(DSN|USER)\s*: ' \+ \$env", "never print the raw values")

    def test_e2e_checks_its_configuration_and_fails_fast_with_a_clear_message(self):
        steps = {s.get("name"): s["run"] for s in self.wf("e2e-oracle19c.yml")["jobs"]["e2e"]["steps"] if "run" in s}
        first = steps["Check the runner configuration and the secret"]
        for needle in ("ORACLE_DSN", "ORACLE_USER", "::error", "exit 1"):
            self.assertIn(needle, first)

    def test_e2e_waits_five_minutes_and_runs_strict(self):
        text = "\n".join(r for _, r in run_blocks(self.wf("e2e-oracle19c.yml")))
        self.assertRegex(text, r"-Strict")
        self.assertRegex(text, r"-WaitForDatabase\s+300\b")

    def test_e2e_takes_the_windows_build_from_the_latest_successful_ci_run_on_main(self):
        doc = self.wf("e2e-oracle19c.yml")
        text = "\n".join(r for _, r in run_blocks(doc))
        self.assertIn("workflows/ci.yml/runs?branch=main&exclude_pull_requests=true&status=success", text)
        steps = doc["jobs"]["e2e"]["steps"]
        dl = [s for s in steps if str(s.get("uses", "")).startswith("actions/download-artifact")]
        self.assertEqual(len(dl), 1)
        self.assertEqual(dl[0]["with"]["name"], "duckdb_oracle-windows_amd64")
        self.assertIn("run-id", dl[0]["with"])

    def test_e2e_only_ever_tests_a_build_of_a_commit_on_main_pushed_to_this_repository(self):
        # The binary is loaded into duckdb.exe on the machine that holds the database credentials. "branch=main" alone also
        # matches a pull request from a fork's branch called main (and a tag called main), whose artifact anyone can produce.
        text = "\n".join(r for _, r in run_blocks(self.wf("e2e-oracle19c.yml")))
        self.assertIn("exclude_pull_requests=true", text, "never let pull-request runs into the result list")
        self.assertRegex(text, r"@\('push', 'workflow_dispatch'\) -notcontains \$run\.event", "re-check the event of every run the API returned")
        self.assertRegex(text, r"\$run\.head_repository\.full_name -ne \$env:GITHUB_REPOSITORY", "re-check that the run is from this repository")
        self.assertRegex(text, r"compare/main\.\.\.\$\(\$run\.head_sha\)", "check that the built commit is on main")
        self.assertRegex(text, r"@\('identical', 'behind'\) -notcontains \$cmp\.status",
                         "only a commit that is on main (identical to it or behind it) may be tested, nothing else")

    def test_e2e_has_no_zig_or_python_steps(self):
        text = read(WORKFLOWS, "e2e-oracle19c.yml")
        self.assertNotIn("setup-zig", text)
        self.assertNotIn("zig build", text)

    # ---- the shared build/test steps and the artifact list ------------------------------
    def test_every_platform_in_build_zig_is_built_verified_and_uploaded(self):
        build_zig = read(REPO, "build.zig")
        enum = re.search(r"const Platform = enum \{(.*?)\n    fn target", build_zig, re.S).group(1)
        platforms = set(re.findall(r"^\s{4}([a-z0-9_]+),\s*$", enum, re.M))
        self.assertGreaterEqual(len(platforms), 5, platforms)
        comp = load(COMPOSITE)
        steps = comp["runs"]["steps"]
        build_cmd = " ".join(s["run"] for s in steps if "Build all platforms" in s.get("name", ""))
        built = set(re.findall(r"-Dplatform=([a-z0-9_]+)", build_cmd))
        uploaded = {s["with"]["name"] for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact")}
        self.assertEqual(built, platforms, "the composite action must build every platform in build.zig")
        self.assertEqual(uploaded, {f"duckdb_oracle-{p}" for p in platforms}, "one artifact per platform")
        for s in steps:
            if str(s.get("uses", "")).startswith("actions/upload-artifact"):
                self.assertEqual(s["if"], "inputs.upload-artifacts == 'true'")
                self.assertEqual(s["with"]["path"], f"zig-out/dist/{s['with']['name']}.zip")
        verify = " ".join(s["run"] for s in steps if "Verify artifacts" in s.get("name", ""))
        for p in platforms:
            self.assertIn(p, verify)

    def test_ci_loads_the_linux_build_into_the_pinned_stock_cli(self):
        steps = load(COMPOSITE)["runs"]["steps"]
        text = "\n".join(s.get("run", "") for s in steps)
        self.assertIn("fetch-duckdb-cli.sh linux-amd64", text)
        self.assertRegex(text, r"verify_artifact\.py check .*duckdb_oracle-linux_amd64\.zip.*--duckdb")


class PinsAndTests(unittest.TestCase):
    def test_the_duckdb_cli_pin_is_complete_and_the_only_place_for_the_version(self):
        pins = json.loads(read(HERE, "duckdb-cli-pins.json"))
        self.assertRegex(pins["version"], r"^v\d+\.\d+\.\d+$")
        for asset in ("duckdb_cli-linux-amd64.zip", "duckdb_cli-windows-amd64.zip", "duckdb_cli-windows-arm64.zip"):
            self.assertRegex(pins["sha256"][asset], r"^[0-9a-f]{64}$", asset)
        # no workflow, composite action or script spells out a DuckDB CLI download or version of its own
        files = glob.glob(os.path.join(WORKFLOWS, "*.yml")) + [COMPOSITE, os.path.join(REPO, "test-windows.ps1")]
        for path in files:
            text = read(path)
            self.assertNotIn("duckdb/releases/download/v", text, path)
            self.assertNotRegex(text, r"DUCKDB_BASELINE|DuckDBVersion\s*=\s*'v\d", path)

    def test_the_e2e_sql_follows_its_conventions(self):
        setup_dir = os.path.join(REPO, "test", "e2e", "setup") + os.sep
        files = sorted(f for f in glob.glob(os.path.join(REPO, "test", "e2e", "**", "*.sql"), recursive=True) if not f.startswith(setup_dir))
        self.assertGreaterEqual(len(files), 12)
        for path in files:
            name = os.path.relpath(path, REPO)
            text = read(path)
            head = []
            for line in text.splitlines():
                if line.strip() and not line.lstrip().startswith("--"):
                    break
                head.append(line.strip())
            self.assertTrue(any(h.startswith("-- e2e:") for h in head), f"{name}: needs a '-- e2e: <title>' header")
            self.assertRegex(text, r"oracle_(query|scan|tables)\('@DSN@'", name)
            # comments may explain where the login comes from; the SQL itself must never carry it
            sql = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--")).lower()
            self.assertNotRegex(sql, r"password|getenv|current_setting|\bsecret", name)
            self.assertNotRegex(sql, r"\buser\s*:=\s*'(?!e2e_no_such_user)", name)
            expects_error = any(h.startswith("-- expect-error:") for h in head)
            if expects_error:
                # a file that expects an error must keep running after it, or it cannot prove the process survives
                self.assertIn(".bail off", text, f"{name}: expect-error files need '.bail off'")
            elif "00_server_version" not in name:
                self.assertIn("error(", text, f"{name}: a passing test must assert with error()")
            # nothing may create or change Oracle objects (12_errors deliberately sends rejected statements)
            if "12_errors" not in name:
                self.assertNotRegex(sql, r"'\s*(create|drop|alter|insert|update|delete|truncate|merge|grant)\s", name)

    def test_the_e2e_setup_scripts_stop_on_error_and_only_touch_e2e_objects(self):
        scripts = sorted(glob.glob(os.path.join(REPO, "test", "e2e", "setup", "*", "*.sql")))
        self.assertGreaterEqual(len(scripts), 1)
        for path in scripts:
            name = os.path.relpath(path, REPO)
            text = read(path)
            self.assertRegex(text, r"(?im)^WHENEVER SQLERROR (EXIT FAILURE|CONTINUE)\s*$", f"{name}: say explicitly what an error does")
            body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
            # these scripts run as SYSTEM: they may never touch anything that is not an E2E_ object
            self.assertNotRegex(body, r"(?i)\b(alter\s+(system|database)|shutdown|startup)\b", name)
            for m in re.finditer(r"(?i)\b(drop|create)\s+(?:or\s+replace\s+)?(?:public\s+)?(?:user|synonym|table|view)\s+(?:if\s+exists\s+)?([\w.\"$#]+)", body):
                self.assertRegex(m.group(2).strip('"'), r"(?i)^(e2e_\w*|e2e_app\.e2e_\w*|e2e_\w+\.e2e_\w*|e2e_\w+\.\"?\w+\"?)$", f"{name}: {m.group(0)}")

    def test_the_documented_runner_label_and_env_keys_match_the_workflow(self):
        doc = read(REPO, "docs", "SELF_HOSTED_RUNNER.md")
        wf = read(WORKFLOWS, "e2e-oracle19c.yml")
        for key in ("ORACLE_DSN", "ORACLE_USER", "ORACLE_CONTAINER", "ORACLE_PASSWORD", "oracle19c"):
            self.assertIn(key, doc)
            self.assertIn(key, wf)


if __name__ == "__main__":
    unittest.main()
