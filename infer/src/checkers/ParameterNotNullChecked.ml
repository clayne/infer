(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module IRAttributes = Attributes
module F = Format

module DomainData = struct
  type t = {checked: bool} [@@deriving compare]

  let pp fmt {checked} = F.fprintf fmt "checked=%b" checked
end

module BlockParams = struct
  include PrettyPrintable.MakePPMonoMap (Mangled) (DomainData)

  let compare = compare DomainData.compare
end

module Vars = struct
  include PrettyPrintable.MakePPMonoMap (Ident) (Mangled)

  let compare = compare Mangled.compare
end

module TraceData = struct
  type data_usage = Assign | CheckNil | Execute | Parameter of Procname.t [@@deriving compare]

  type t = {arg: Mangled.t; loc: Location.t; usage: data_usage} [@@deriving compare]

  let to_string arg usage =
    match usage with
    | Assign ->
        "Assigned"
    | CheckNil ->
        F.asprintf "Checking `%a` for nil" Mangled.pp arg
    | Execute ->
        F.asprintf "Executing `%a`" Mangled.pp arg
    | Parameter proc_name ->
        F.asprintf "Parameter `%a` of %a" Mangled.pp arg Procname.pp proc_name


  let pp fmt {arg; loc; usage} =
    F.fprintf fmt "%a at %a, usage is %s" Mangled.pp arg Location.pp loc (to_string arg usage)
end

module TraceInfo = struct
  type t = TraceData.t list [@@deriving compare]

  let pp = Pp.semicolon_seq TraceData.pp
end

module Mem = struct
  type t = {vars: Vars.t; blockParams: BlockParams.t; traceInfo: TraceInfo.t [@compare.ignore]}
  [@@deriving compare]

  let pp fmt {vars; blockParams; traceInfo} =
    F.fprintf fmt "Vars= %a@.BlockParams= %a@.TraceInfo= %a" Vars.pp vars BlockParams.pp blockParams
      TraceInfo.pp traceInfo


  let find_block_param id (astate : t) = Vars.find_opt id astate.vars

  let exec_null_check_id id loc ({vars; blockParams; traceInfo} as astate : t) =
    match find_block_param id astate with
    | Some name ->
        let traceInfo = {TraceData.arg= name; loc; usage= CheckNil} :: traceInfo in
        let blockParams = BlockParams.add name {checked= true} blockParams in
        {vars; blockParams; traceInfo}
    | None ->
        astate


  let load id pvar _ astate =
    let name = Pvar.get_name pvar in
    let vars =
      if BlockParams.mem name astate.blockParams then Vars.add id name astate.vars else astate.vars
    in
    {astate with vars}


  let set_checked name ~checked blockParams =
    BlockParams.update name (Option.map ~f:(fun _ -> {DomainData.checked})) blockParams


  let store pvar e loc ({vars; blockParams; traceInfo} as astate) =
    let name = Pvar.get_name pvar in
    let traceInfo = {TraceData.arg= name; loc; usage= Assign} :: traceInfo in
    let blockParams =
      match e with
      | Exp.Var id -> (
        match find_block_param id astate with
        | Some param_name -> (
          match BlockParams.find_opt param_name blockParams with
          | Some param_checked ->
              BlockParams.add name param_checked blockParams
          | None ->
              blockParams )
        | None ->
            (* we assigned something else to this formal so we shouldn't report anymore. *)
            set_checked name ~checked:true blockParams )
      | _ when Exp.is_null_literal e ->
          set_checked name ~checked:false blockParams
      | _ ->
          (* we assigned something else to this formal so we shouldn't report anymore. *)
          set_checked name ~checked:true blockParams
    in
    {vars; blockParams; traceInfo}


  let call_trace name loc traceInfo = {TraceData.arg= name; loc; usage= Execute} :: traceInfo

  let make_trace var traceInfo =
    List.fold_left
      ~f:(fun trace_elems {TraceData.arg; loc; usage} ->
        if Mangled.equal var arg then
          let trace_elem = Errlog.make_trace_element 0 loc (TraceData.to_string arg usage) [] in
          trace_elem :: trace_elems
        else trace_elems )
      ~init:[] traceInfo


  let report_unchecked_block_param_issues proc_desc err_log var loc
      ({traceInfo; blockParams} as astate : t) =
    match find_block_param var astate with
    | Some name -> (
      match BlockParams.find_opt name blockParams with
      | Some {checked} when not checked ->
          let traceInfo = call_trace name loc traceInfo in
          let ltr = make_trace name traceInfo in
          let message =
            F.asprintf
              "The block `%a` is executed without a check for nil at %a. This could cause a crash."
              Mangled.pp name Location.pp loc
          in
          Reporting.log_issue proc_desc err_log ~ltr ~loc ParameterNotNullChecked
            IssueType.block_parameter_not_null_checked message ;
          ()
      | _ ->
          () )
    | None ->
        ()
end

module Domain = struct
  include AbstractDomain.FiniteSet (Mem)

  let exec_null_check_id id loc astate = map (Mem.exec_null_check_id id loc) astate

  let load id pvar loc astate = map (Mem.load id pvar loc) astate

  let store pvar e loc astate = map (Mem.store pvar e loc) astate

  let report_unchecked_block_param_issues proc_desc err_log var loc astate =
    iter (Mem.report_unchecked_block_param_issues proc_desc err_log var loc) astate
end

module TransferFunctions = struct
  module Domain = Domain
  module CFG = ProcCfg.Normal

  type analysis_data = IntraproceduralAnalysis.t

  let pp_session_name _node fmt = F.pp_print_string fmt "ParameterNotNullChecked"

  let exec_instr (astate : Domain.t) {IntraproceduralAnalysis.proc_desc; err_log} _cfg_node _
      (instr : Sil.instr) =
    match instr with
    | Load {id; e= Lvar pvar; loc} ->
        Domain.load id pvar loc astate
    | Store {e1= Lvar pvar; e2; loc} ->
        Domain.store pvar e2 loc astate
    | Prune (Var id, loc, _, _) ->
        Domain.exec_null_check_id id loc astate
    (* If (block != nil) or equivalent else branch *)
    | Prune (BinOp (Binop.Ne, e1, e2), loc, _, _)
    (* If (!(block == nil)) or equivalent else branch *)
    | Prune (UnOp (LNot, BinOp (Binop.Eq, e1, e2), _), loc, _, _) -> (
      match (e1, e2) with
      | Var id, e when Exp.is_null_literal e ->
          Domain.exec_null_check_id id loc astate
      | e, Var id when Exp.is_null_literal e ->
          Domain.exec_null_check_id id loc astate
      | _ ->
          astate )
    | Call (_, Exp.Const (Const.Cfun procname), (Exp.Var var, _) :: _, loc, call_flags)
      when Procname.equal procname BuiltinDecl.__call_objc_block
           && call_flags.CallFlags.cf_is_objc_block ->
        Domain.report_unchecked_block_param_issues proc_desc err_log var loc astate ;
        astate
    | _ ->
        astate
end

module Analyzer = AbstractInterpreter.MakeWTO (TransferFunctions)

let find_block_param formals name =
  List.find
    ~f:(fun (formal, typ, _) -> Mangled.equal formal name && Typ.is_pointer_to_function typ)
    formals


let is_block_param formals name =
  List.exists
    ~f:(fun ((formal, typ, _), _) -> Mangled.equal formal name && Typ.is_pointer_to_function typ)
    formals


let get_captured_formals attributes =
  let captured = attributes.ProcAttributes.captured in
  let formal_of_captured (captured : CapturedVar.t) =
    match captured.is_formal_of with
    | Some procname -> (
      match IRAttributes.load procname with
      | Some proc_attributes ->
          let formals =
            find_block_param proc_attributes.ProcAttributes.formals (Pvar.get_name captured.pvar)
          in
          Option.bind ~f:(fun formals -> Some (formals, proc_attributes)) formals
      | None ->
          None )
    | None ->
        None
  in
  List.filter_map ~f:formal_of_captured captured


let init_block_params formals_attributes =
  let add_nullable_block (blockParams, traceInfo) ((formal, _, annotation), attributes) =
    if is_block_param formals_attributes formal && not (Annotations.ia_is_nonnull annotation) then
      let procname = attributes.ProcAttributes.proc_name in
      let blockParams = BlockParams.add formal {checked= false} blockParams in
      let usage = TraceData.Parameter procname in
      let traceInfo =
        {TraceData.arg= formal; loc= attributes.ProcAttributes.loc; usage} :: traceInfo
      in
      (blockParams, traceInfo)
    else (blockParams, traceInfo)
  in
  List.fold formals_attributes ~init:(BlockParams.empty, []) ~f:add_nullable_block


let checker ({IntraproceduralAnalysis.proc_desc} as analysis_data) =
  let attributes = Procdesc.get_attributes proc_desc in
  let captured_formals_attributes = get_captured_formals attributes in
  let formals_attributes =
    List.map ~f:(fun formal -> (formal, attributes)) attributes.ProcAttributes.formals
  in
  let initial_blockParams, initTraceInfo =
    init_block_params (List.append formals_attributes captured_formals_attributes)
  in
  let initial =
    Domain.singleton
      {Mem.vars= Vars.empty; blockParams= initial_blockParams; traceInfo= initTraceInfo}
  in
  ignore (Analyzer.compute_post analysis_data ~initial proc_desc)
