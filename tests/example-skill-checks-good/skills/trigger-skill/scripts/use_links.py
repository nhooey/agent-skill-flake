"""Imports a module and a package linked into scripts/, and the standard
library's zlib, though a link named zlib.so sits beside it."""

import zlib

import linked_module
from linked_package import shout

print(shout(linked_module.NAME), zlib.ZLIB_VERSION)
