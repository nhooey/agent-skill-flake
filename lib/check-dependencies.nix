# The function `root-check-dependencies` applies to a flake's
# `checks.<system>`, with `nix eval --apply`: it returns the path of a store
# file, written by evaluation alone, that lists each check's derivation and
# refers to it. Rooting that one file keeps every check's `.drv` and, through
# the `.drv` files' references, every input derivation of every check; with
# `keep-outputs = true` the garbage collector then keeps each of those
# derivations' outputs that are already in the store, such as crane's
# `cargoArtifacts`. `unsafeDiscardOutputDependency` makes each reference a
# plain store path rather than a derivation output, so neither evaluating
# nor rooting the file builds anything.
checks:
builtins.toFile "check-dependencies" (
  builtins.concatStringsSep "" (
    map (name: builtins.unsafeDiscardOutputDependency checks.${name}.drvPath + "\n") (
      builtins.attrNames checks
    )
  )
)
