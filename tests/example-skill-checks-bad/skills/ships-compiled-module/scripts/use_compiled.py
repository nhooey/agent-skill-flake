"""Imports the standard library's sqlite3 and zlib, though files named like
compiled modules of theirs sit beside it."""

import sqlite3
import zlib

print(sqlite3.sqlite_version, zlib.ZLIB_VERSION)
