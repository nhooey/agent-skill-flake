"""Imports packages, a namespace package and a linked package beside it."""

import bundled
from space import part
from linked_package import shout
import empty

print(bundled.NAME, part.NAME, shout("imports-a-package"), empty.__name__)
