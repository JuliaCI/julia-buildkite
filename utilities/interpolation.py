"""
bash-like `${VAR}` interpolation of arches-templated pipeline YAMLs, used by
render_launch_pipeline.py.
"""

import re


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
