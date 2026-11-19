# content-hash.bash — the hash that tells two copies of a skill apart.
#
# A skill's version string is the same for every build of it, and its store
# path changes with the nixpkgs it was built against, so neither says
# whether two copies hold the same skill. This hash does: it covers each
# entry's path relative to the skill folder, its kind (directory, file,
# executable file, or symlink with its target) and each file's bytes, in
# C-locale order. The sentinel ($SENTINEL_FILE) is left out, since it
# records which agent-skill-flake built the copy, not what the copy holds.
#
# A hash reads `<scheme>:<hex>`, where the scheme ($CONTENT_HASH_SCHEME)
# names how it was computed. A change to what the hash covers takes a new
# scheme, and a reader compares two recorded hashes only when their schemes
# match.
#
# Sourced by mkSkill's build, which records the hash in the sentinel as
# `contentHash`, by withNamePrefix's, and by reconcile. Needs GNU find,
# sort, xargs, sha256sum and cut, and SENTINEL_FILE set.

CONTENT_HASH_SCHEME="v1:sha256"

# skill_content_hash <dir> -> `<scheme>:<hex>` of the skill folder <dir>.
# Returns 1, printing nothing on stdout, when part of <dir> can't be read.
skill_content_hash() {
  local hex
  hex=$(
    set -o pipefail
    cd -P -- "$1" || exit 1
    {
      find . -mindepth 1 ! -path "./$SENTINEL_FILE" \( \
        -type l -printf 'symlink %p -> %l\0' -o \
        -type d -printf 'dir %p\0' -o \
        -type f -perm -u=x -printf 'exec %p\0' -o \
        -type f -printf 'file %p\0' \) | LC_ALL=C sort -z || exit 1
      find . -mindepth 1 -type f ! -path "./$SENTINEL_FILE" -print0 |
        LC_ALL=C sort -z | xargs -0 -r sha256sum -- || exit 1
    } | sha256sum | cut -c1-64
  ) || return 1
  printf '%s:%s' "$CONTENT_HASH_SCHEME" "$hex"
}

# content_hash_extend <hash> <text> -> a hash of <hash> and <text> in
# <hash>'s scheme: a hash for a skill derived from another one, such as the
# same content renamed, or wrapped with different script inputs.
content_hash_extend() {
  printf '%s:%s' "$(content_hash_scheme "$1")" \
    "$(printf '%s\n%s\n' "$1" "$2" | sha256sum | cut -c1-64)"
}

# content_hash_scheme <hash> -> <hash> without its final `:<hex>`.
content_hash_scheme() {
  printf '%s' "${1%:*}"
}
