# Single source of truth for the awk pass that normalizes a skill's
# *installed* SKILL.md so its top-level frontmatter `name:` equals the
# canonical name. This is the half a directory rename can't do alone:
# Claude Code reads the frontmatter `name:` in preference to the
# directory, so a rename that didn't rewrite it would silently keep the
# old identity.
#
# Only the first `---`-fenced block is touched, and only a column-0
# `name:` key (an indented `name:` under e.g. `metadata:` is correctly
# left alone); if the block has no `name:` one is injected; a file with
# no frontmatter gets one synthesized.
#
# The script reads the target name from the awk variable `newname`, so
# callers invoke it as `awk -v newname=<name> -f <this-script> SKILL.md`.
# Both `mkSkill` (lib/internal.nix) and `withNamePrefix`
# (lib/with-name-prefix.nix) wrap this string in `pkgs.writeText` and run
# it identically — keeping the rename contract defined in exactly one place.
''
  BEGIN { state = 0; seen = 0 }
  NR == 1 && $0 != "---" {
    print "---"
    print "name: " newname
    print "---"
    print ""
    print
    state = 2
    next
  }
  NR == 1 {
    print
    state = 1
    next
  }
  state == 1 && $0 == "---" {
    if (seen == 0) print "name: " newname
    print
    state = 2
    next
  }
  state == 1 && /^name[[:blank:]]*:/ {
    print "name: " newname
    seen = 1
    next
  }
  { print }
''
