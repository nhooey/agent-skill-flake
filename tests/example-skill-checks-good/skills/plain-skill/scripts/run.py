"""Imports only the standard library and the modules beside it."""

from __future__ import annotations

import json
import os.path
import sqlite3

import common
from helpers import greet

print(json.dumps([os.path.sep, common.NAME, greet(), sqlite3.sqlite_version]))
