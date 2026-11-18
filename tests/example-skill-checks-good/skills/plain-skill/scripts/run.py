"""Imports only the standard library and the modules beside it."""

from __future__ import annotations

import json
import os.path
import sqlite3

import common

print(json.dumps([os.path.sep, common.NAME, sqlite3.sqlite_version]))
