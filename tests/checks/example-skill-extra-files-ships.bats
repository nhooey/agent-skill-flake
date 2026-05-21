#!/usr/bin/env bats
# Inputs: SKILL_ROOT — install root of a build with
#         extraFiles = [ "*.md" "*.sh" "*.dot" ]
setup() { source "$BATS_HELPERS"; }

@test "extraFiles ships loose top-level companions referenced from SKILL.md" {
  assert [ -f "$SKILL_ROOT/SKILL.md" ]
  assert [ -f "$SKILL_ROOT/visual-companion.md" ]
  assert [ -f "$SKILL_ROOT/helper.sh" ]
  assert [ -f "$SKILL_ROOT/graph.dot" ]
}

@test "extraFiles preserves the standard subdir surface" {
  assert [ -f "$SKILL_ROOT/references/note.md" ]
  refute [ -e "$SKILL_ROOT/companion-dir" ]
}

@test "SKILL.md is the awk-normalized version, not the source copy" {
  # The `*.md` glob matches SKILL.md too, so extraFiles would copy the
  # source SKILL.md to the install root. The installPhase orders
  # extraFiles BEFORE the awk pass so the normalized SKILL.md wins.
  # The source SKILL.md has a `# example-skill-extra-files` heading;
  # after awk it still starts with the frontmatter block.
  run head -n 1 "$SKILL_ROOT/SKILL.md"
  assert_output "---"
  # Frontmatter `name:` is normalized to the canonical effective name.
  run grep -E '^name:' "$SKILL_ROOT/SKILL.md"
  assert_output "name: example-skill-extra-files"
}
