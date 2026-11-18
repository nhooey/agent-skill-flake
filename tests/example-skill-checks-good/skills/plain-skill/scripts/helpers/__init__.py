"""A package in scripts/, which the repository's tests may import and the
scripts beside it don't."""

import sys


def greet():
    return f"hello from Python {sys.version_info.major}"
