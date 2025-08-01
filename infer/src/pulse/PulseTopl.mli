(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open PulseBasicInterface
module BaseDomain = PulseBaseDomain

type value = AbstractValue.t

type static_type = Typ.t

type value_and_type = value * static_type

type event =
  | ArrayWrite of {aw_array: value; aw_index: value}
  | Call of {return: value_and_type option; arguments: value_and_type list; procname: Procname.t}

type state [@@deriving compare, equal]

(** This is a subset of [AbductiveDomain.t], which is needed to evolve the topl state. The purpose
    of this type is to avoid a cyclic dependency between [PulseTopl] and [PulseAbductiveDomain], so
    that we can keep them separate. The problem is as follows. A [PulseAbductiveDomain.t] has a
    [PulseTopl.state] as a component. Evolving a [PulseAbductiveDomain.t] must (a) evolve the
    non-topl parts without looking at the topl parts, which is why [PulseTopl.state] is abstract,
    and (b) trigger the evolution of the topl parts, which *should* look at the non-topl parts of
    the abductive domain. Those necessary non-topl parts are what [PulseTopl.pulse_state] contains.*)
type pulse_state = {pulse_post: BaseDomain.t; pulse_pre: BaseDomain.t; path_condition: Formula.t}

val start : unit -> state
(** Return the initial state of [Topl.automaton ()]. *)

val small_step : Tenv.t -> Location.t -> pulse_state -> event -> state -> state

val large_step :
     call_location:Location.t
  -> callee_proc_name:Procname.t
  -> substitution:(value * ValueHistory.t) AbstractValue.Map.t
  -> pulse_state
  -> callee_summary:state
  -> callee_is_manifest:bool
  -> state
  -> state
(** [large_step ~call_location ~callee_proc_name ~substitution pulse_state ~callee_summary 
     ~callee_is_manifest state] updates [state] according to [callee_summary]. The abstract values
    in [pulse_state] and [state] are in one scope, and those in [callee_summary] in another scope:
    the [substitution] maps from the callee scope to the caller scope. *)

val filter_for_summary : pulse_state -> state -> state
(** Remove infeasible and ambiguous simple states. *)

val simplify : pulse_state -> state -> state
(** Drop redundant predicates and detect infeasible simple states. Best effort. *)

val report_errors : Procdesc.t -> Errlog.t -> pulse_is_manifest:bool -> state -> unit
(** Calls [Reporting.log_issue] with error traces, if any. *)

val pp_state : Format.formatter -> state -> unit

module Debug : sig
  val get_dropped_disjuncts_count : unit -> int
end
