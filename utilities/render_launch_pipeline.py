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

SOURCE_BUILD=true renders the standard Build / Test / Allow Fail groups with
every build compiling its dependencies from source (USE_BINARYBUILDER=0) --
see the source-build mode section below. It is meant for manual "New Build"
runs (the New Build dialog's environment box reaches this renderer through
the launch step's env), e.g. to check that the release branch still builds
from source before tagging.
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
# source-build mode (SOURCE_BUILD=true)
# --------------------------------------------------------------------------
# Renders the standard per-commit pipeline, but with every build job compiling
# its dependencies from source instead of downloading BinaryBuilder tarballs.
# The test jobs are unchanged (they consume whatever artifact the build
# produced), so this answers "does this ref build from source on every
# platform, and does the result pass the test suite" -- e.g. on a release
# branch before tagging, where the from-source path otherwise only gets
# exercised by users after the release.
#
# Deliberate differences from the normal per-commit render:
#   * every build row gets USE_BINARYBUILDER=0 appended to MAKE_FLAGS (a
#     make command-line flag, so it overrides Make.user and the environment)
#     and the from-source TIMEOUT (compiling LLVM dwarfs the BB timeouts);
#   * Linux rows are moved from the package_linux rootfs onto llvm_passes:
#     package_linux has no gfortran (OpenBLAS) and is missing parts of the
#     from-source toolchain -- llvm_passes carries the full toolchain (it is
#     the image the scheduled source build uses on julia-buildkite main);
#   * no publish wait/trigger: source-built binaries must never be promoted;
#   * no Check group: its jobs build julia their own way regardless of
#     MAKE_FLAGS, so they would only duplicate the normal CI run's work
#     without testing the source build;
#   * the github_commit_status contexts are suffixed " (source build)" so a
#     manual run cannot overwrite the commit's real Build / Test statuses.
SOURCE_BUILD = os.environ.get("SOURCE_BUILD") == "true"

# Minutes; matches the from-source build row in build_linux.schedule.arches.
SOURCE_BUILD_TIMEOUT = 240

# ARCH_ROOTFS -> (image, tag, treehash) replacing package_linux rows.
# Treehashes are the artifact_hash values from the rootfs-images v8.5 release
# build (its "Linux" GitHub Actions run); x86_64 matches the llvm_passes hash
# already pinned in misc/analyzegc.yml.
SOURCE_BUILD_ROOTFS = {
    "x86_64":  ("llvm_passes", "v8.5", "630126d5595f428ef824651b9be020ffc485eb6f"),
    "i686":    ("llvm_passes", "v8.5", "3d1a64df225c1ee12fe8bc554bd2ac946a99e02e"),
    "aarch64": ("llvm_passes", "v8.5", "7e5f35dd121157cb0efda4d84f33d55b8b76b36a"),
}


def apply_source_build(env, yaml_file, where):
    """Mutate one per-commit build row for source-build mode. Test rows pass
    through untouched: they depend on the build key and download its artifact
    regardless of how it was produced."""
    if not yaml_file.startswith("build_"):
        return
    flags = env.get("MAKE_FLAGS", "")
    env["MAKE_FLAGS"] = (flags + "," if flags else "") + "USE_BINARYBUILDER=0"
    timeout = int(env["TIMEOUT"]) if env.get("TIMEOUT", "").isdigit() else 0
    env["TIMEOUT"] = str(max(timeout, SOURCE_BUILD_TIMEOUT))
    image = env.get("ROOTFS_IMAGE_NAME", "")
    if image == "package_linux":
        name, tag, treehash = SOURCE_BUILD_ROOTFS[env["ARCH_ROOTFS"]]
        env["ROOTFS_IMAGE_NAME"] = name
        env["ROOTFS_TAG"] = tag
        env["ROOTFS_HASH"] = treehash
    elif image:
        # e.g. package_linux_mmtk: no from-source-capable variant exists, so
        # the row keeps its image and its build shows what actually breaks.
        sys.stderr.write(f"{where}: source-build mode keeps rootfs {image}\n")


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
# YAML step extraction (text-only; no YAML library)
# --------------------------------------------------------------------------
# Every platform / misc YAML we care about has the shape:
#   steps:
#     - group: "<label>"
#       [notify: ...]
#       steps:
#         - <one or more inner step blocks>
# We want the inner step block(s) so we can re-group them. We operate on raw
# text (not a YAML round-trip) to preserve `$$` escapes and formatting exactly.
#
# These files are structurally regular, so instead of parsing them we slice the
# indented text block under a given key. The launch agents have no PyYAML, so
# the renderer must stay stdlib-only; we emit text we control (re-indented to a
# canonical depth) so indentation and `$$` stay byte-exact.

# Canonical indentation of the emitted document: the merged inner step blocks
# live under `    steps:` of `  - group:`, so each step block's leading `- `
# sits at 6 spaces, matching the platform sources.
STEP_INDENT = 6


def _split_lines(text):
    """Split into lines WITHOUT dropping a trailing newline's emptiness.
    Returns the list of lines (no line endings)."""
    return text.split("\n")


def _indent_of(line):
    """Number of leading spaces; None for a blank/whitespace-only line."""
    stripped = line.lstrip(" ")
    if stripped == "":
        return None
    return len(line) - len(stripped)


def _find_group_label(text, where):
    """Return the group label string from the single `  - group: "<label>"`
    top-level entry. Parses the quoted (or bare) scalar after `group:`."""
    for line in _split_lines(text):
        m = re.match(r'\s*- group:\s*(.*?)\s*$', line)
        if m:
            return _scalar(m.group(1))
    raise AssertionError(f"{where}: no top-level group found")


def _scalar(raw):
    """Decode a simple YAML scalar: a double/single-quoted string or a bare
    word. Sufficient for the group labels in these files."""
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
        return raw[1:-1]
    return raw


def _reindent_step_block(block_lines):
    """Re-indent a sliced inner-steps block so each step's `- ` sits at
    STEP_INDENT spaces. The block's own base indent (indent of the first
    non-blank line) is stripped and replaced. Relative indentation -- and thus
    every `$$` byte -- is preserved."""
    base = None
    for line in block_lines:
        ind = _indent_of(line)
        if ind is not None:
            base = ind
            break
    if base is None:
        return ""
    shift = STEP_INDENT - base
    out = []
    for line in block_lines:
        if line.strip() == "":
            out.append("")
            continue
        if shift >= 0:
            out.append(" " * shift + line)
        else:
            # Remove up to -shift leading spaces (block is more deeply indented
            # than canonical). All lines share at least `base` spaces.
            out.append(line[-shift:])
    return "\n".join(out)


def extract_inner_steps_text(text, where):
    """From a single-group document's text, return the re-indented text of all
    inner step blocks under the group's `steps:` key (6-space `- ` indent).

    The block continues until the text dedents back out of the group (a line
    indented <= the `  - group:` indent). This deliberately does NOT bound on
    the `steps:` key indent, because some sources (sanitizers/asan.yml,
    tsan.yml) put their list items at the SAME indent as `steps:` -- still
    inside the group -- which a strict `> steps_indent` rule would drop."""
    lines = _split_lines(text)

    # Locate the `  - group:` line and its indent (the group boundary).
    group_indent = None
    group_idx = None
    for i, line in enumerate(lines):
        ind = _indent_of(line)
        if ind is None:
            continue
        if re.match(r'\s*- group:\s', line) or re.match(r'\s*- group:\s*$', line):
            group_indent = ind
            group_idx = i
            break
    assert group_idx is not None, f"{where}: no group line found"

    # Find the group's own `steps:` key (the first `steps:` AFTER the group line
    # that is indented deeper than the group line).
    start = None
    for i in range(group_idx + 1, len(lines)):
        line = lines[i]
        ind = _indent_of(line)
        if ind is None:
            continue
        if ind <= group_indent:
            break  # left the group without finding steps:
        if re.match(rf'\s*steps:\s*$', line):
            start = i + 1
            break
    assert start is not None, f"{where}: group has no steps: key"

    block = []
    for line in lines[start:]:
        ind = _indent_of(line)
        if ind is None:
            block.append(line)
            continue
        if ind <= group_indent:
            break  # dedented out of the group
        block.append(line)
    while block and block[-1].strip() == "":
        block.pop()
    return _reindent_step_block(block)


def load_group_text(path):
    """Return (group_label, inner_steps_text) for a single-group YAML file,
    with inner step blocks re-indented to the canonical depth. Verbatim bytes
    (incl. `$$`) within each step body are preserved."""
    with open(path) as f:
        text = f.read()
    label = _find_group_label(text, path)
    return label, extract_inner_steps_text(text, path)


def render_arches_group_text(arches_file, yaml_file, group, allow_fail,
                             extra_env=None):
    """Render the inner step block of an arches-templated platform YAML once
    per arch. Interpolation is applied to the source TEXT first, then the inner
    steps are sliced out. Returns the concatenated re-indented step text."""
    arches_path = os.path.join(PLATFORMS, arches_file)
    yaml_path = os.path.join(PLATFORMS, yaml_file)
    with open(yaml_path) as f:
        template_text = f.read()

    chunks = []
    for arch_env in arches_envs(arches_path):
        env = dict(arch_env)
        env["GROUP"] = group
        env["ALLOW_FAIL"] = allow_fail
        if extra_env:
            env.update(extra_env)
        where = f"{yaml_file} [{arch_env.get('TRIPLET', '?')}]"
        if SOURCE_BUILD:
            apply_source_build(env, yaml_file, where)
        rendered = interpolate(template_text, env, where)
        chunks.append(extract_inner_steps_text(rendered, where))
    return "\n".join(c for c in chunks if c)


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
    "source_dist.yml",
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


# --------------------------------------------------------------------------
# group emission (text)
# --------------------------------------------------------------------------
# A merged group is emitted as:
#     - group: "<label>"
#     [notify block]
#     steps:
#       <concatenated 6-space step blocks>
# The notify block per merged group is fixed (the old Build/Check/Test groups
# carried `notify: [{github_commit_status: {context: <label>}}]`). Allow Fail
# carried no notify.

# Notify context per merged group label (None => no notify block).
GROUP_NOTIFY = {
    "Build": "Build",
    "Check": "Check",
    "Test": "Test",
    "Allow Fail": None,
}


def emit_group(label, steps_text):
    """Build the text of one merged `  - group:` block. `steps_text` is the
    already-re-indented (6-space `- `) concatenation of inner step blocks."""
    out = [f'  - group: "{label}"']
    context = GROUP_NOTIFY.get(label)
    if context is not None and SOURCE_BUILD:
        context += " (source build)"
    if context is not None:
        out.append("    notify:")
        out.append("      - github_commit_status:")
        out.append(f'          context: "{context}"')
    out.append("    steps:")
    if steps_text:
        out.append(steps_text)
    return "\n".join(out)


def verbatim_group_text(path):
    """Return the entire `  - group:` ... block text of a single-group file,
    VERBATIM (no interpolation, no re-indentation). Strips leading comment /
    blank lines before `steps:` and any trailing blank lines."""
    with open(path) as f:
        text = f.read()
    lines = _split_lines(text)
    # Find the top-level `- group:` line (indent 2).
    start = None
    for i, line in enumerate(lines):
        if re.match(r'  - group:', line):
            start = i
            break
    assert start is not None, f"{path}: no top-level group found"
    block = lines[start:]
    while block and block[-1].strip() == "":
        block.pop()
    return "\n".join(block)


def build_group_text():
    chunks = []
    for arches, yml in BUILD_ARCHES:
        chunks.append(render_arches_group_text(arches, yml, "Build", "false"))
    return emit_group("Build", "\n".join(c for c in chunks if c))


def check_group_text():
    chunks = []
    for rel in CHECK_STATIC:
        label, inner = load_group_text(os.path.join(MISC, rel))
        assert label == "Check", f"{rel}: expected Check group, got {label!r}"
        chunks.append(inner)
    return emit_group("Check", "\n".join(c for c in chunks if c))


def test_group_text():
    chunks = []
    for rel in TEST_STATIC:
        label, inner = load_group_text(os.path.join(MISC, rel))
        assert label == "Test", f"{rel}: expected Test group, got {label!r}"
        chunks.append(inner)
    for arches, yml in TEST_ARCHES:
        chunks.append(render_arches_group_text(arches, yml, "Test", "false"))
    return emit_group("Test", "\n".join(c for c in chunks if c))


def allow_fail_group_text():
    chunks = []
    for arches, yml in ALLOW_FAIL_BUILD_ARCHES:
        chunks.append(render_arches_group_text(arches, yml, "Allow Fail", "true"))
    for arches, yml in ALLOW_FAIL_TEST_ARCHES:
        chunks.append(render_arches_group_text(arches, yml, "Allow Fail", "true"))
    return emit_group("Allow Fail", "\n".join(c for c in chunks if c))


# Trailing barrier + trigger of the trusted julia-publish pipeline (inlined
# verbatim so the wait reliably barriers all dynamically-uploaded jobs).
TRAILER = '''\
  - wait: ~
  - trigger: "julia-publish"
    label: ":rocket: trigger publish"
    if: pipeline.slug == "julia-ci"
    build:
      commit: "${BUILDKITE_COMMIT}"
      branch: "${BUILDKITE_BRANCH}"
      message: "publish: ${BUILDKITE_MESSAGE}"'''


def main():
    if SOURCE_BUILD:
        # See the source-build mode section up top for what is (and is not)
        # rendered here and why. No TRAILER: never publish a source build.
        blocks = [
            build_group_text(),
            test_group_text(),
            allow_fail_group_text(),
        ]
        sys.stdout.write("steps:\n")
        sys.stdout.write("\n".join(blocks))
        sys.stdout.write("\n")
        return

    blocks = [
        build_group_text(),
        check_group_text(),
        test_group_text(),
        allow_fail_group_text(),
    ]

    # NOTE (release-julia-1.13): the JuliaSyntax and JuliaC launch groups that
    # `main` emits here are intentionally omitted on the release branch -- they
    # are not part of release-1.13's CI job set (the pre-#544 launch flow never
    # uploaded juliasyntax.launch.yml or juliac/test_juliac.yml). This port
    # changes only the trust/routing architecture, not which jobs run; per-
    # release job-set differences are expressed as branch content selected by
    # julia's in-repo .buildkite-external-version pointer. To opt release-1.13
    # into either group, re-add the corresponding `blocks.append(...)` from
    # `main` (the juliasyntax.* / juliac/ YAMLs are already present in-tree).

    sys.stdout.write("steps:\n")
    sys.stdout.write("\n".join(blocks))
    sys.stdout.write("\n")
    sys.stdout.write(TRAILER)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
