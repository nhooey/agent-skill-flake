# inside companion-dir

This file is inside a top-level directory other than references/scripts.
The `extraFiles = [ "*" ]` directory-skip test asserts that
`companion-dir` is NOT shipped (it's not in `extraDirs`) — only the
top-level regular files are.
