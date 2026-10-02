"""
bash-like `${VAR}` interpolation of arches-templated pipeline YAMLs, used by
render_launch_pipeline.py and interpolate_from_env.py, so that every arches
template is interpolated by the same code.
"""

import re


# Match a $$ runtime escape (left untouched) or a ${...} expansion.
_VAR_RE = re.compile(r'\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)([?+-]|:[?+-])?((?:[^{}]|\{[^}]*\})*)\}')


def interpolate(text, env, where):
    """Resolve single-$ ${VAR}, ${VAR?}, ${VAR:?}, ${VAR-d}, ${VAR:-d},
    ${VAR+a}, ${VAR:+a} against `env`. $$ escapes are left untouched."""
    def repl(m):
        if m.group(0) == "$$":
            return "$$"
        name, op, arg = m.group(1), m.group(2), m.group(3)
        if op is None and arg:
            # e.g. ${VAR:0:2}, which would otherwise expand to plain ${VAR}
            raise ValueError(f"{where}: unsupported expansion {m.group(0)}")
        present = name in env
        value = env.get(name, "")
        if "$" in value:
            # `buildkite-agent pipeline upload` would interpolate it again
            raise ValueError(f"{where}: value of ${{{name}}} contains `$`")
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
