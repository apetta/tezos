(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Double endorsement evidence operation may happen when an endorser
    endorsed two different blocks on the same level. *)

open Proto_alpha
open Alpha_context

(****************************************************************)
(*                  Utility functions                           *)
(****************************************************************)

let get_first_different_baker baker bakers =
  return @@ List.find (fun baker' ->
      Signature.Public_key_hash.(<>) baker baker')
    bakers

let get_first_different_bakers ctxt =
  Context.get_bakers ctxt >>=? fun bakers ->
  let baker_1 = List.hd bakers in
  get_first_different_baker baker_1 (List.tl bakers) >>=? fun baker_2 ->
  return (baker_1, baker_2)

let get_first_different_endorsers ctxt =
  Context.get_endorsers ctxt >>=? fun endorsers ->
  let endorser_1 = (List.hd endorsers) in
  let endorser_2 = (List.hd (List.tl endorsers)) in
  return (endorser_1, endorser_2)

let block_fork b =
  get_first_different_bakers (B b) >>=? fun (baker_1, baker_2) ->
  Block.bake ~policy:(By_account baker_1) b >>=? fun blk_a ->
  Block.bake ~policy:(By_account baker_2) b >>=? fun blk_b ->
  return (blk_a, blk_b)

(****************************************************************)
(*                        Tests                                 *)
(****************************************************************)

(** Simple scenario where two endorsements are made from the same
    delegate and exposed by a double_endorsement operation. Also verify
    that punishment is operated. *)
let valid_double_endorsement_evidence () =
  Context.init 2 >>=? fun (b, _) ->

  block_fork b >>=? fun (blk_a, blk_b) ->

  Context.get_endorser (B blk_a) 0 >>=? fun delegate ->
  Op.endorsement ~delegate (B blk_a) [0] >>=? fun endorsement_a ->
  Op.endorsement ~delegate (B blk_b) [0] >>=? fun endorsement_b ->
  Block.bake ~operations:[endorsement_a] blk_a >>=? fun blk_a ->
  (* Block.bake ~operations:[endorsement_b] blk_b >>=? fun _ -> *)

  Op.double_endorsement (B blk_a) endorsement_a endorsement_b >>=? fun operation ->

  (* Bake with someone different than the bad endorser *)
  Context.get_bakers (B blk_a) >>=? fun bakers ->
  get_first_different_baker delegate bakers >>=? fun baker ->

  Block.bake ~policy:(By_account baker) ~operation blk_a >>=? fun blk ->

  (* Check that the frozen deposit, the fees and rewards are removed *)
  iter_s (fun kind ->
      let contract = Alpha_context.Contract.implicit_contract delegate in
      Assert.balance_is ~loc:__LOC__ (B blk) contract ~kind Tez.zero)
    [ Deposit ; Fees ; Rewards ]
(* TODO : check also that the baker receive half of the bad endorser's frozen balance *)

(****************************************************************)
(*  The following test scenarios are supposed to raise errors.  *)
(****************************************************************)

(** Check that an invalid double endorsement operation that exposes a valid
    endorsement fails. *)
let invalid_double_endorsement () =
  Context.init 10 >>=? fun (b, _) ->
  Block.bake b >>=? fun b ->

  Op.endorsement (B b) [0] >>=? fun endorsement ->
  Block.bake ~operation:endorsement b >>=? fun b ->

  Op.double_endorsement (B b) endorsement endorsement >>=? fun operation ->
  Block.bake ~operation b >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res begin function
    | Apply.Invalid_double_endorsement_evidence -> true
    | _ -> false end

(** Check that a double endorsement added at the same time as a double
    endorsement operation fails. *)
let too_early_double_endorsement_evidence () =
  Context.init 2 >>=? fun (b, _) ->
  block_fork b >>=? fun (blk_a, blk_b) ->

  Context.get_endorser (B blk_a) 0 >>=? fun delegate ->
  Op.endorsement ~delegate (B blk_a) [0] >>=? fun endorsement_a ->
  Op.endorsement ~delegate (B blk_b) [0] >>=? fun endorsement_b ->

  Op.double_endorsement (B b) endorsement_a endorsement_b >>=? fun operation ->
  Block.bake ~operation b >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res begin function
    | Apply.Too_early_double_endorsement_evidence _ -> true
    | _ -> false end

(** Check that after [preserved_cycles + 1], it is not possible
    to create a double_endorsement anymore. *)
let too_late_double_endorsement_evidence () =
  Context.init 2 >>=? fun (b, _) ->
  Context.get_constants (B b)
  >>=? fun Constants.{ parametric = { preserved_cycles ; _ } ; _ } ->

  block_fork b >>=? fun (blk_a, blk_b) ->

  Context.get_endorser (B blk_a) 0 >>=? fun delegate ->
  Op.endorsement ~delegate (B blk_a) [0] >>=? fun endorsement_a ->
  Op.endorsement ~delegate (B blk_b) [0] >>=? fun endorsement_b ->

  fold_left_s (fun blk _ -> Block.bake_until_cycle_end blk)
    blk_a (1 -- (preserved_cycles + 1)) >>=? fun blk ->

  Op.double_endorsement (B blk) endorsement_a endorsement_b >>=? fun operation ->
  Block.bake ~operation blk >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res begin function
    | Apply.Outdated_double_endorsement_evidence _ -> true
    | _ -> false end

(** Check that an invalid double endorsement evidence that expose two
    endorsements made by two different endorsers fails. *)
let different_delegates () =
  Context.init 2 >>=? fun (b, _) ->

  block_fork b >>=? fun (blk_a, blk_b) ->
  get_first_different_endorsers (B blk_a)
  >>=? fun (endorser_a, endorser_b) ->

  Op.endorsement ~delegate:endorser_a.delegate (B blk_a) endorser_a.slots >>=? fun e_a ->
  Op.endorsement ~delegate:endorser_b.delegate (B blk_b) endorser_b.slots >>=? fun e_b ->
  Op.double_endorsement (B blk_a) e_a e_b >>=? fun operation ->
  Block.bake ~operation blk_a >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res begin function
    | Apply.Inconsistent_double_endorsement_evidence _ -> true
    | _ -> false end

(** Check that a double endorsement evidence that exposes a ill-formed
    endorsement fails. *)
let wrong_delegate () =
  Context.init 2 >>=? fun (b, _) ->

  block_fork b >>=? fun (blk_a, blk_b) ->
  get_first_different_endorsers (B blk_a)
  >>=? fun (endorser_a, endorser_b) ->

  Op.endorsement ~delegate:endorser_b.delegate (B blk_a) endorser_a.slots >>=? fun endorsement_a ->
  Op.endorsement ~delegate:endorser_b.delegate (B blk_b) endorser_b.slots >>=? fun endorsement_b ->

  Op.double_endorsement (B blk_a) endorsement_a endorsement_b >>=? fun operation ->
  Block.bake ~operation blk_a >>= fun e ->
  Assert.proto_error ~loc:__LOC__ e begin function
    | Operation_repr.Invalid_signature -> true
    | _ -> false end

let tests = [
  Test.tztest "valid double endorsement evidence" `Quick valid_double_endorsement_evidence ;

  Test.tztest "invalid double endorsement evidence" `Quick invalid_double_endorsement ;
  Test.tztest "too early double endorsement evidence" `Quick too_early_double_endorsement_evidence ;
  Test.tztest "too late double endorsement evidence" `Quick too_late_double_endorsement_evidence ;
  Test.tztest "different delegates" `Quick different_delegates ;
  Test.tztest "wrong delegate" `Quick wrong_delegate ;
]
