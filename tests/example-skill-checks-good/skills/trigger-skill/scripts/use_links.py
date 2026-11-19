"""Imports a module linked into scripts/ and the standard library's zlib."""

import zlib

import linked_module

print(linked_module.NAME, zlib.ZLIB_VERSION)
