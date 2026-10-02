#!/usr/bin/env python3
"""
Interpolate one arches template against the process env and print it.

`arches_pipeline_upload.sh` exports each row of an `.arches` file and then runs
this on the template, uploading the result, so that arch vars are resolved by
interpolation.py (exactly as render_launch_pipeline.py resolves them) rather
than by `buildkite-agent pipeline upload` directly.
"""

import argparse
import os
import sys

from interpolation import interpolate


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("template", metavar="TEMPLATE",
                        help="the arches template to interpolate")
    args = parser.parse_args()
    with open(args.template) as f:
        template_text = f.read()
    sys.stdout.write(interpolate(template_text, dict(os.environ), args.template))


if __name__ == "__main__":
    main()
