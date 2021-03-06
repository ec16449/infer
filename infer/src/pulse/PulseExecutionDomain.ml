(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module AbductiveDomain = PulseAbductiveDomain

type exec_state =
  | AbortProgram of AbductiveDomain.t
  | ContinueProgram of AbductiveDomain.t
  | ExitProgram of AbductiveDomain.t

type t = exec_state

let continue astate = ContinueProgram astate

let mk_initial pdesc = ContinueProgram (AbductiveDomain.mk_initial pdesc)

let leq ~lhs ~rhs =
  match (lhs, rhs) with
  | AbortProgram astate1, AbortProgram astate2
  | ContinueProgram astate1, ContinueProgram astate2
  | ExitProgram astate1, ExitProgram astate2 ->
      AbductiveDomain.leq ~lhs:astate1 ~rhs:astate2
  | _ ->
      false


let pp fmt = function
  | ContinueProgram astate ->
      AbductiveDomain.pp fmt astate
  | ExitProgram astate ->
      F.fprintf fmt "{ExitProgram %a}" AbductiveDomain.pp astate
  | AbortProgram astate ->
      F.fprintf fmt "{AbortProgram %a}" AbductiveDomain.pp astate


let map ~f exec_state =
  match exec_state with
  | AbortProgram astate ->
      AbortProgram (f astate)
  | ContinueProgram astate ->
      ContinueProgram (f astate)
  | ExitProgram astate ->
      ExitProgram (f astate)


let of_post pdesc = map ~f:(AbductiveDomain.of_post pdesc)
