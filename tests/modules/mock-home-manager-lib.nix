# Augmented `lib` for the home-manager-module tests — passed via
# `specialArgs` so `lib.hm.dag.entryAfter` resolves from the very first
# module evaluation pass (no fixpoint race with `_module.args.lib`). Real
# home-manager exposes `lib.hm.dag.entryAfter` as a tagged record; tests
# only inspect `.data`, so the stand-in is simplified to data + after.
{ lib }:
lib
// {
  hm = (lib.hm or { }) // {
    dag = {
      entryAfter = after: data: { inherit after data; };
    };
  };
}
