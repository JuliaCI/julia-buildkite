#!/usr/bin/env python3
"""
Pre-merge renderer for the Julia Buildkite CI launch flow.

Instead of the launch agent making ~30 separate `buildkite-agent pipeline
upload` calls (each a ~1.5s network round-trip that dominates launch latency),
this renderer produces ONE pre-grouped pipeline document on stdout. The launch
step then does a SINGLE `buildkite-agent pipeline upload` of that document.

It reproduces, exactly, what `launch_untrusted_builders.yml` used to upload:

  * The arches-templated platform YAMLs
    (pipelines/main/platforms/{build,test}_*.yml) are rendered once per arch.
    The per-arch `${VAR}` / `${VAR?}` / `${VAR-default}` substitutions that the
    `buildkite-agent pipeline upload` of those files used to perform are done
    HERE, using the env produced by `utilities/arches_env.sh <file.arches>`
    plus GROUP / ALLOW_FAIL. (`USE_RR` comes from the .arches file itself where
    relevant.)

  * The static / nested misc YAMLs (misc/analyzegc.yml, misc/gcext.yml, the
    juliac / juliasyntax launchers, ...) are emitted VERBATIM. We do NOT
    pre-resolve their variables: they contain only `$$`-runtime escapes and/or
    launch-agent-env vars (e.g. `${ALLOW_FAIL?}` on gcext/test_revise). The
    final single `buildkite-agent pipeline upload` of this combined document
    interpolates those with the launch-agent env -- exactly as the old
    per-file uploads did -- and converts `$$` -> `$`.

CRITICAL interpolation rule: a `$$` (double dollar) is a Buildkite runtime
escape and must be PRESERVED verbatim. Per-arch substitution here only touches
single-`$` `${...}` references that are NOT preceded by another `$`.

PowerPC: `launch_powerpc.jl` only uploads powerpc arches for Julia < 1.12. On
current master (1.14) it is a no-op, so the powerpc arches are intentionally
omitted (see OMITTED_POWERPC below). This matches the runtime behaviour.

The result is grouped into one `group:` per label: Build, Check, Test,
Allow Fail, JuliaSyntax, JuliaC.
"""

import os
import re
import subprocess
import sys

# Directory of the .buildkite checkout root (this file lives in
# <root>/utilities/render_launch_pipeline.py).
UTIL_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(UTIL_DIR)
ARCHES_ENV_SH = os.path.join(UTIL_DIR, "arches_env.sh")

PLATFORMS = os.path.join(ROOT, "pipelines", "main", "platforms")
MISC = os.path.join(ROOT, "pipelines", "main", "misc")


# --------------------------------------------------------------------------
# arches parsing (reuse arches_env.sh; do NOT reimplement .arches parsing)
# --------------------------------------------------------------------------

def arches_envs(arches_path):
    """Return a list of dicts, one per arch row, by shelling out to
    arches_env.sh and faithfully parsing each `NAME="value" ...` line via
    bash `eval` so quoting matches exactly what arches_pipeline_upload.sh
    would have exported."""
    out = subprocess.run(
        ["bash", ARCHES_ENV_SH, arches_path],
        check=True, capture_output=True, text=True,
    ).stdout

    envs = []
    for line in out.splitlines():
        if not line.strip():
            continue
        # The names assigned on this line (in order).
        names = re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=', line)
        # Re-evaluate the assignment line in a clean bash so quoting is handled
        # identically to `eval "export $env_map"`, then dump exactly those
        # names as NUL-delimited "name=value" records to parse unambiguously
        # (values may contain spaces, '=', and ',').
        script = (
            'eval "$1"; shift\n'
            'for n in "$@"; do printf "%s=%s\\0" "$n" "${!n}"; done\n'
        )
        dump = subprocess.run(
            ["bash", "-c", script, "_", line, *names],
            check=True, capture_output=True, text=True,
        ).stdout
        env = {}
        for rec in dump.split("\0"):
            if "=" not in rec:
                continue
            k, v = rec.split("=", 1)
            env[k] = v
        envs.append(env)
    return envs


# --------------------------------------------------------------------------
# bash-like ${VAR} interpolation for the arches-templated YAMLs
# --------------------------------------------------------------------------

# Match a single-$ ${...} that is NOT preceded by another $ (i.e. not part of
# a $$ runtime escape). We assert the char before the $ is not a $.
_VAR_RE = re.compile(r'(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)([?+-]|:[?+-])?((?:[^{}]|\{[^}]*\})*)\}')


def interpolate(text, env, where):
    """Resolve single-$ ${VAR}, ${VAR?}, ${VAR:?}, ${VAR-d}, ${VAR:-d},
    ${VAR+a}, ${VAR:+a} against `env`. $$ escapes are left untouched because
    the regex refuses a $ immediately before the ${."""
    def repl(m):
        name, op, arg = m.group(1), m.group(2), m.group(3)
        present = name in env
        value = env.get(name, "")
        if op in (None, ""):
            if not present:
                raise KeyError(f"{where}: undefined arch var ${{{name}}}")
            return value
        colon = op.startswith(":")
        kind = op[-1]
        # "unset or null" when colon; just "unset" otherwise.
        empty = (not present) if not colon else (not present or value == "")
        if kind == "?":
            if empty:
                raise KeyError(
                    f"{where}: required arch var ${{{name}{op}}} is unset/empty"
                )
            return value
        if kind == "-":
            return arg if empty else value
        if kind == "+":
            return arg if not empty else ""
        raise AssertionError(op)
    return _VAR_RE.sub(repl, text)


# --------------------------------------------------------------------------
# YAML step extraction
# --------------------------------------------------------------------------
# Every platform / misc YAML we care about has the shape:
#   steps:
#     - group: "<label>"
#       [notify: ...]
#       steps:
#         - <one inner step>
# We want the inner step block(s) so we can re-group them. We operate on raw
# text (not a YAML round-trip) to preserve `$$` escapes and formatting exactly.

import yaml  # noqa: E402  (import here so the module-level docstring runs first)


def load_group(path):
    """Load a YAML file expected to contain a single top-level group and
    return (group_label, notify_obj_or_None, [inner_step_dicts])."""
    with open(path) as f:
        doc = yaml.safe_load(f)
    steps = doc["steps"]
    assert len(steps) == 1, f"{path}: expected exactly one top-level group"
    group = steps[0]
    assert "group" in group, f"{path}: top-level entry is not a group"
    return group["group"], group.get("notify"), group["steps"]


def render_arches_group(arches_file, yaml_file, group, allow_fail,
                        extra_env=None):
    """Render the inner step of an arches-templated platform YAML once per
    arch. Returns a list of inner-step dicts (parsed YAML)."""
    arches_path = os.path.join(PLATFORMS, arches_file)
    yaml_path = os.path.join(PLATFORMS, yaml_file)
    with open(yaml_path) as f:
        template_text = f.read()

    inner_steps = []
    for arch_env in arches_envs(arches_path):
        env = dict(arch_env)
        env["GROUP"] = group
        env["ALLOW_FAIL"] = allow_fail
        if extra_env:
            env.update(extra_env)
        where = f"{yaml_file} [{arch_env.get('TRIPLET', '?')}]"
        rendered = interpolate(template_text, env, where)
        doc = yaml.safe_load(rendered)
        # doc is {steps: [{group:..., steps:[inner]}]}
        grp = doc["steps"][0]
        for inner in grp["steps"]:
            inner_steps.append(inner)
    return inner_steps


# Each tuple mirrors a `arches_pipeline_upload.sh <arches> <yaml>` call from
# the old launch_untrusted_builders.yml, with its GROUP / ALLOW_FAIL.

BUILD_ARCHES = [
    ("build_linux.arches",   "build_linux.yml"),
    ("build_macos.arches",   "build_macos.yml"),
    ("build_freebsd.arches", "build_freebsd.yml"),
    ("build_windows.arches", "build_windows.yml"),
]

TEST_ARCHES = [
    ("test_linux.arches",      "test_linux.yml"),
    ("test_linux.i686.arches", "test_linux.i686.yml"),
    ("test_macos.arches",      "test_macos.yml"),
    ("test_freebsd.arches",    "test_freebsd.yml"),
    ("test_windows.arches",    "test_windows.yml"),
]

ALLOW_FAIL_BUILD_ARCHES = [
    ("build_linux.soft_fail.arches", "build_linux.yml"),
    ("build_macos.soft_fail.arches", "build_macos.yml"),
]

ALLOW_FAIL_TEST_ARCHES = [
    ("test_linux.soft_fail.arches",   "test_linux.yml"),
    # PowerPC (test_linux.powerpc.soft_fail) intentionally omitted -- no-op on
    # Julia >= 1.12. See OMITTED_POWERPC.
    ("test_macos.soft_fail.arches",   "test_macos.yml"),
    ("test_freebsd.soft_fail.arches", "test_freebsd.yml"),
    ("test_windows.soft_fail.arches", "test_windows.yml"),
]

OMITTED_POWERPC = [
    "build_linux.powerpc.arches -> build_linux.yml (Build)",
    "test_linux.powerpc.soft_fail.arches -> test_linux.yml (Allow Fail)",
]

# Static (verbatim) misc YAMLs that the old Check step uploaded, in order.
CHECK_STATIC = [
    "analyzegc.yml",
    "doctest.yml",
    "pdf_docs/build_pdf_docs.yml",
    "embedding.yml",
    "trimming.yml",
    "llvmpasses.yml",
    "sanitizers/asan.yml",
    "sanitizers/tsan.yml",
]

# Static misc YAMLs the old Test step uploaded verbatim (group "Test").
TEST_STATIC = [
    "gcext.yml",
    "test_revise.yml",
]


def build_group():
    steps = []
    for arches, yml in BUILD_ARCHES:
        steps += render_arches_group(arches, yml, "Build", "false")
    return {
        "group": "Build",
        "notify": [{"github_commit_status": {"context": "Build"}}],
        "steps": steps,
    }


def check_group():
    steps = []
    notify = None
    for rel in CHECK_STATIC:
        label, n, inner = load_group(os.path.join(MISC, rel))
        assert label == "Check", f"{rel}: expected Check group, got {label!r}"
        if n is not None:
            notify = n
        steps += inner
    return {
        "group": "Check",
        "notify": notify or [{"github_commit_status": {"context": "Check"}}],
        "steps": steps,
    }


def test_group():
    steps = []
    notify = None
    for rel in TEST_STATIC:
        label, n, inner = load_group(os.path.join(MISC, rel))
        assert label == "Test", f"{rel}: expected Test group, got {label!r}"
        if n is not None:
            notify = n
        steps += inner
    for arches, yml in TEST_ARCHES:
        steps += render_arches_group(arches, yml, "Test", "false")
    return {
        "group": "Test",
        "notify": notify or [{"github_commit_status": {"context": "Test"}}],
        "steps": steps,
    }


def allow_fail_group():
    steps = []
    for arches, yml in ALLOW_FAIL_BUILD_ARCHES:
        steps += render_arches_group(arches, yml, "Allow Fail", "true")
    for arches, yml in ALLOW_FAIL_TEST_ARCHES:
        steps += render_arches_group(arches, yml, "Allow Fail", "true")
    return {"group": "Allow Fail", "steps": steps}


def verbatim_group(path):
    """Return the single top-level group of `path` as a parsed dict, verbatim
    (no per-arch interpolation -- it stays a launcher / static job and is
    resolved by the final pipeline upload)."""
    with open(path) as f:
        doc = yaml.safe_load(f)
    assert len(doc["steps"]) == 1
    return doc["steps"][0]


def main():
    groups = [build_group(), check_group(), test_group(), allow_fail_group()]

    # JuliaSyntax: gated on ./JuliaSyntax/Project.toml existing in the julia
    # checkout (same conditional the old Check step used). Included verbatim
    # as its own group (it is itself a launcher with its own notify).
    juliasyntax_project = os.path.join(os.getcwd(), "JuliaSyntax", "Project.toml")
    if os.path.exists(juliasyntax_project):
        groups.append(verbatim_group(os.path.join(MISC, "juliasyntax.launch.yml")))
    else:
        sys.stderr.write(
            "./JuliaSyntax/Project.toml does NOT exist; omitting JuliaSyntax group\n"
        )

    # JuliaC: itself a launcher with its own group + notify -- include verbatim.
    groups.append(verbatim_group(os.path.join(MISC, "juliac", "test_juliac.yml")))

    # Barrier + trigger of the trusted julia-publish pipeline (inlined verbatim
    # so the wait reliably barriers all dynamically-uploaded jobs).
    doc = {
        "steps": groups + [
            {"wait": None},
            {
                "trigger": "julia-publish",
                "label": ":rocket: trigger publish",
                "if": 'pipeline.slug == "julia-ci"',
                "build": {
                    "commit": "${BUILDKITE_COMMIT}",
                    "branch": "${BUILDKITE_BRANCH}",
                    "message": "publish: ${BUILDKITE_MESSAGE}",
                },
            },
        ]
    }

    yaml.safe_dump(doc, sys.stdout, default_flow_style=False, sort_keys=False,
                   width=10_000)


if __name__ == "__main__":
    main()
