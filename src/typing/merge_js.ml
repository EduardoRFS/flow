(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type options = {
  metadata: Context.metadata;
  lint_severities: Severity.severity LintSettings.t;
  strict_mode: StrictModeSettings.t;
}

module ALocSet = Loc_collections.ALocSet

module Reqs = struct
  type dep_impl = Context.sig_t * ALocSet.t

  type unchecked = ALocSet.t

  type res = ALocSet.t

  type decl = ALocSet.t * Modulename.t

  type t = {
    (* dep_impls: edges from files in the component to cxs of direct dependencies,
     * when implementations are found *)
    dep_impls: dep_impl SMap.t;
    (* unchecked: edges from files in the component to files which are known to
     * exist are not checked (no @flow, @noflow, unparsed). Note that these
     * dependencies might be provided by a (typed) libdef, but we don't know yet. *)
    unchecked: unchecked SMap.t;
    (* res: edges between files in the component and resource files, labeled
     * with the requires they denote. *)
    res: res SMap.t;
    (* decls: edges between files in the component and libraries, classified
     * by requires (when implementations of such requires are not found). *)
    decls: decl SMap.t;
  }

  let empty =
    { dep_impls = SMap.empty; unchecked = SMap.empty; res = SMap.empty; decls = SMap.empty }

  let add_dep_impl =
    let combine (from_cx, locs1) (_, locs2) = (from_cx, ALocSet.union locs1 locs2) in
    fun require (from_cx, require_locs) reqs ->
      let dep_impls = SMap.add ~combine require (from_cx, require_locs) reqs.dep_impls in
      { reqs with dep_impls }

  let add_unchecked require require_locs reqs =
    let unchecked = SMap.add ~combine:ALocSet.union require require_locs reqs.unchecked in
    { reqs with unchecked }

  let add_res require require_locs reqs =
    let res = SMap.add ~combine:ALocSet.union require require_locs reqs.res in
    { reqs with res }

  let add_decl =
    let combine (locs1, modulename) (locs2, _) = (ALocSet.union locs1 locs2, modulename) in
    fun require (require_locs, modulename) reqs ->
      let decls = SMap.add ~combine require (require_locs, modulename) reqs.decls in
      { reqs with decls }
end

module ImplicitInstantiationKit : Implicit_instantiation.KIT = Implicit_instantiation.Make (struct
  type output = unit

  let on_constant_tparam _ _ = ()

  let on_pinned_tparam _ _ _ = ()

  let on_missing_bounds cx name ~tparam_binder_reason ~instantiation_reason =
    Flow_js.add_output
      cx
      (Error_message.EImplicitInstantiationUnderconstrainedError
         { bound = name; reason_call = instantiation_reason; reason_l = tparam_binder_reason })

  let on_upper_non_t cx name u ~tparam_binder_reason ~instantiation_reason:_ =
    let msg = name ^ " contains a non-Type.t upper bound " ^ Type.string_of_use_ctor u in
    Flow_js.add_output
      cx
      (Error_message.EImplicitInstantiationTemporaryError
         (Reason.aloc_of_reason tparam_binder_reason, msg))
end)

(* Connect the export of cx_from to its import in cx. *)
let explicit_impl_require cx (cx_from, m, loc) =
  let from_t = Context.find_module_sig cx_from m in
  let to_t = Context.find_require cx loc in
  Flow_js.flow_t cx (from_t, to_t)

(* Create the export of a resource file on the fly and connect it to its import in cx. *)
let explicit_res_require cx (loc, f) =
  (* Recall that a resource file is not parsed, so its export doesn't depend on
     its contents, just its extension. So, we create the export of a resource
     file on the fly by looking at its extension. The general alternative of
     writing / reading these exports to / from separate contexts that live in a
     shared heap takes more time / space (linear in the number of resource
     files), so we avoid it. This optimization is analogous to what we do for
     unchecked files: we create the export (`any`) on the fly instead of writing
     / reading it to / from the context of each unchecked file. *)
  let from_t = Import_export.mk_resource_module_t cx loc f in
  let to_t = Context.find_require cx loc in
  Flow_js.flow_t cx (from_t, to_t)

(* Connect a export of a declared module to its import in cx. *)
let explicit_decl_require cx (m, loc, resolved_m) =
  let reason = Reason.(mk_reason (RCustom m) loc) in
  (* lookup module declaration from builtin context *)
  let resolved_m_name = resolved_m |> Modulename.to_string in
  if resolved_m = Modulename.String Type.react_server_module_ref then
    Flow_js.add_output cx (Error_message.EImportInternalReactServerModule loc);
  let m_name =
    if
      (resolved_m = Modulename.String "react" || resolved_m = Modulename.String "React")
      && Context.in_react_server_component_file cx
    then
      Type.react_server_module_ref
    else
      resolved_m_name
  in
  let m_name_internal = m_name |> Reason.internal_module_name in
  let from_t = Flow_js_utils.lookup_builtin_strict cx m_name_internal reason in

  (* flow the declared module type to importing context *)
  let to_t = Context.find_require cx loc in
  Flow_js.flow_t cx (from_t, to_t)

(* Connect exports of an unchecked module to its import in cx. Note that we
   still lookup the module instead of returning `any` directly. This is because
   a resolved-unchecked dependency is superceded by a possibly-checked libdef.
   See unchecked_*_module_vs_lib tests for examples. *)
let explicit_unchecked_require cx (m, loc) =
  (* Use a special reason so we can tell the difference between an any-typed type import
   * from an untyped module and an any-typed type import from a nonexistent module. *)
  let reason = Reason.(mk_reason (RUntypedModule m) loc) in
  let m_name = Reason.internal_module_name m in
  let default_t = Type.AnyT (reason, Type.Untyped) in
  let from_t = Flow_js.lookup_builtin_with_default cx m_name default_t in

  (* flow the declared module type to importing context *)
  let to_t = Context.find_require cx loc in
  Flow_js.flow_t cx (from_t, to_t)

let detect_sketchy_null_checks cx =
  let add_error ~loc ~null_loc kind falsy_loc =
    Error_message.ESketchyNullLint { kind; loc; null_loc; falsy_loc } |> Flow_js.add_output cx
  in
  let detect_function exists_excuses loc exists_check =
    ExistsCheck.(
      let exists_excuse =
        Loc_collections.ALocMap.find_opt loc exists_excuses |> Base.Option.value ~default:empty
      in
      match exists_check.null_loc with
      | None -> ()
      | Some null_loc ->
        let add_error = add_error ~loc ~null_loc in
        if Base.Option.is_none exists_excuse.bool_loc then
          Base.Option.iter exists_check.bool_loc ~f:(add_error Lints.SketchyNullBool);
        if Base.Option.is_none exists_excuse.number_loc then
          Base.Option.iter exists_check.number_loc ~f:(add_error Lints.SketchyNullNumber);
        if Base.Option.is_none exists_excuse.string_loc then
          Base.Option.iter exists_check.string_loc ~f:(add_error Lints.SketchyNullString);
        if Base.Option.is_none exists_excuse.mixed_loc then
          Base.Option.iter exists_check.mixed_loc ~f:(add_error Lints.SketchyNullMixed);
        if Base.Option.is_none exists_excuse.enum_bool_loc then
          Base.Option.iter exists_check.enum_bool_loc ~f:(add_error Lints.SketchyNullEnumBool);
        if Base.Option.is_none exists_excuse.enum_number_loc then
          Base.Option.iter exists_check.enum_number_loc ~f:(add_error Lints.SketchyNullEnumNumber);
        if Base.Option.is_none exists_excuse.enum_string_loc then
          Base.Option.iter exists_check.enum_string_loc ~f:(add_error Lints.SketchyNullEnumString);
        ())
  in
  Loc_collections.ALocMap.iter
    (detect_function (Context.exists_excuses cx))
    (Context.exists_checks cx)

let detect_test_prop_misses cx =
  let misses = Context.test_prop_get_never_hit cx in
  Base.List.iter
    ~f:(fun (prop_name, (reason_prop, reason_obj), use_op) ->
      Flow_js.add_output
        cx
        (Error_message.EPropNotFound
           { prop_name; reason_prop; reason_obj; use_op; suggestion = None }))
    misses

let detect_unnecessary_optional_chains cx =
  Base.List.iter
    ~f:(fun (loc, lhs_reason) ->
      Flow_js.add_output cx (Error_message.EUnnecessaryOptionalChain (loc, lhs_reason)))
    (Context.unnecessary_optional_chains cx)

let detect_unnecessary_invariants cx =
  Base.List.iter
    ~f:(fun (loc, reason) ->
      Flow_js.add_output cx (Error_message.EUnnecessaryInvariant (loc, reason)))
    (Context.unnecessary_invariants cx)

let detect_invalid_type_assert_calls cx typed_ast file_sig =
  if Context.type_asserts cx then Type_asserts.detect_invalid_calls ~full_cx:cx typed_ast file_sig

let detect_es6_import_export_errors = Strict_es6_import_export.detect_errors

let detect_escaped_generics results =
  Base.List.iter
    ~f:(fun (cx, _, (_, { Flow_ast.Program.statements; _ })) ->
      Generic_escape.scan_for_escapes cx ~add_output:Flow_js.add_output statements)
    results

let detect_non_voidable_properties cx =
  (* This function approximately checks whether VoidT can flow to the provided
   * type without actually creating the flow so as not to disturb type inference.
   * Even though this is happening post-merge, it is possible to encounter an
   * unresolved tvar, in which case it conservatively returns false.
   *)
  let rec is_voidable seen_ids =
    Type.(
      function
      | OpenT (_, id) ->
        (* tvar is recursive: conservatively assume it is non-voidable *)
        if ISet.mem id seen_ids then
          false
        else (
          match Flow_js_utils.possible_types cx id with
          (* tvar has no lower bounds: we conservatively assume it's non-voidable
           * except in the special case when it also has no upper bounds
           *)
          | [] -> Flow_js_utils.possible_uses cx id = []
          (* tvar is resolved: look at voidability of the resolved type *)
          | [t] -> is_voidable (ISet.add id seen_ids) t
          (* tvar is unresolved: conservatively assume it is non-voidable *)
          | _ -> false
        )
      (* a union is voidable if any of its members are voidable *)
      | UnionT (_, rep) -> UnionRep.members rep |> List.exists (is_voidable seen_ids)
      (* an intersection is voidable if all of its members are voidable *)
      | IntersectionT (_, rep) -> InterRep.members rep |> List.for_all (is_voidable seen_ids)
      (* trivially voidable *)
      | MaybeT _
      | DefT (_, _, (VoidT | MixedT (Mixed_everything | Mixed_non_null)))
      | OptionalT _
      | AnyT _ ->
        true
      (* conservatively assume all other types are non-voidable *)
      | _ -> false)
  in
  let check_properties (property_map : Type.Properties.id) :
      ALoc.t Property_assignment.error list SMap.t -> unit =
    let pmap = Context.find_props cx property_map in
    SMap.iter (fun name errors ->
        let should_error =
          match NameUtils.Map.find_opt (Reason.OrdinaryName name) pmap with
          | Some (Type.Field (_, t, _)) -> not @@ is_voidable ISet.empty t
          | _ -> true
        in
        if should_error then
          List.iter
            (fun { Property_assignment.loc; desc } ->
              Flow_js.add_output cx (Error_message.EUninitializedInstanceProperty (loc, desc)))
            errors)
  in
  List.iter
    (fun {
           Context.public_property_map;
           private_property_map;
           errors = { Property_assignment.public_property_errors; private_property_errors };
         } ->
      check_properties public_property_map public_property_errors;
      check_properties private_property_map private_property_errors)
    (Context.voidable_checks cx)

let check_implicit_instantiations cx master_cx =
  if Context.run_post_inference_implicit_instantiation cx then
    let implicit_instantiation_checks = Context.implicit_instantiation_checks cx in
    ImplicitInstantiationKit.fold
      cx
      master_cx
      ~init:()
      ~f:(fun _ _ _ _ -> ())
      ~post:(fun ~init_cx ~cx ->
        let new_errors = Context.errors cx in
        Flow_error.ErrorSet.iter (fun error -> Context.add_error init_cx error) new_errors)
      implicit_instantiation_checks

class resolver_visitor =
  let no_lowers _cx r = Type.Unsoundness.merged_any r in
  object (self)
    inherit [unit] Type_mapper.t_with_uses as super

    method! type_ cx map_cx t =
      let open Type in
      match t with
      | OpenT (r, id) -> Flow_js_utils.merge_tvar ~filter_empty:true ~no_lowers cx r id
      | EvalT (t', dt, _id) ->
        let t'' = self#type_ cx map_cx t' in
        let dt' = self#defer_use_type cx map_cx dt in
        if t' == t'' && dt == dt' then
          t
        else
          Flow_cache.Eval.id cx t'' dt'
      | _ -> super#type_ cx map_cx t

    (* Only called from type_ and the CreateObjWithComputedPropT use case *)
    method tvar _cx _seen _r id = id

    (* overridden in type_ *)
    method eval_id _cx _map_cx _id = assert false

    method props cx map_cx id =
      let props_map = Context.find_props cx id in
      let props_map' =
        NameUtils.Map.ident_map (Type.Property.ident_map_t (self#type_ cx map_cx)) props_map
      in
      let id' =
        if props_map == props_map' then
          id
        (* When mapping results in a new property map, we have to use a
           generated id, rather than a location from source. *)
        else
          Context.generate_property_map cx props_map'
      in
      id'

    (* These should already be fully-resolved. *)
    method exports _cx _map_cx id = id

    method call_prop cx map_cx id =
      let t = Context.find_call cx id in
      let t' = self#type_ cx map_cx t in
      if t == t' then
        id
      else
        Context.make_call_prop cx t'
  end

let detect_matching_props_violations cx =
  let open Type in
  let resolver = new resolver_visitor in
  let step (reason, key, sentinel, obj) =
    let obj = resolver#type_ cx () obj in
    let sentinel = resolver#type_ cx () sentinel in
    match drop_generic sentinel with
    (* TODO: it should not be possible to create a MatchingPropT with a non-tvar tout *)
    | DefT (_, _, (BoolT (Some _) | StrT (Literal _) | NumT (Literal _))) ->
      (* Limit the check to promitive literal sentinels *)
      let use_op =
        Op
          (MatchingProp
             {
               op = reason;
               obj = TypeUtil.reason_of_t obj;
               key;
               sentinel_reason = TypeUtil.reason_of_t sentinel;
             })
      in
      (* If `obj` is a GenericT, we replace it with it's upper bound, since ultimately it will flow into
         `sentinel` rather than the other way around. *)
      Flow_js.flow cx (MatchingPropT (reason, key, sentinel), UseT (use_op, drop_generic obj))
    | _ -> ()
  in
  let matching_props = Context.matching_props cx in
  List.iter step matching_props

let detect_literal_subtypes =
  let lb_visitor = new resolver_visitor in
  let ub_visitor =
    object (self)
      inherit resolver_visitor as super

      method! type_ cx map_cx t =
        let open Type in
        match t with
        | GenericT { bound; _ } -> self#type_ cx map_cx bound
        | t -> super#type_ cx map_cx t
    end
  in
  fun cx ->
    let checks = Context.literal_subtypes cx in
    List.iter
      (fun (t, u) ->
        let t = lb_visitor#type_ cx () t in
        let u = ub_visitor#use_type cx () u in
        Flow_js.flow cx (t, u))
      checks

let get_lint_severities metadata strict_mode lint_severities =
  if metadata.Context.strict || metadata.Context.strict_local then
    StrictModeSettings.fold
      (fun lint_kind lint_severities ->
        LintSettings.set_value lint_kind (Severity.Err, None) lint_severities)
      strict_mode
      lint_severities
  else
    lint_severities

let merge_imports cx reqs =
  let open Reqs in
  reqs.dep_impls
  |> SMap.iter (fun m (cx_from, locs) ->
         ALocSet.iter (fun loc -> explicit_impl_require cx (cx_from, m, loc)) locs);

  reqs.res
  |> SMap.iter (fun f locs -> ALocSet.iter (fun loc -> explicit_res_require cx (loc, f)) locs);

  reqs.decls
  |> SMap.iter (fun m (locs, resolved_m) ->
         ALocSet.iter (fun loc -> explicit_decl_require cx (m, loc, resolved_m)) locs);

  reqs.unchecked
  |> SMap.iter (fun m locs -> ALocSet.iter (fun loc -> explicit_unchecked_require cx (m, loc)) locs)

(* Post-merge errors.
 *
 * At this point, all dependencies have been merged and the component has been
 * linked together. Any constraints should have already been evaluated, which
 * means we can complain about things that either haven't happened yet, or
 * which require complete knowledge of tvar bounds.
 *)
let post_merge_checks cx master_cx ast tast metadata file_sig =
  let results = [(cx, ast, tast)] in
  detect_sketchy_null_checks cx;
  detect_non_voidable_properties cx;
  check_implicit_instantiations cx master_cx;
  detect_test_prop_misses cx;
  detect_unnecessary_optional_chains cx;
  detect_unnecessary_invariants cx;
  detect_invalid_type_assert_calls cx tast file_sig;
  detect_es6_import_export_errors cx metadata results;
  detect_escaped_generics results;
  detect_matching_props_violations cx;
  detect_literal_subtypes cx

(* This function is similar to merge_component in that it merges a component with
   its requires. The difference is that, here, requires are merged _before_ running
   inference on the component. This will be useful in making imported types available
   for local inference of the input component. What makes this change possible is
   that the input component is of size 1 and all imports have already been resolved
   and optimized.
*)
let check_file ~options filename reqs dep_cxs master_cx ast comments file_sig docblock aloc_table =
  let ccx = Context.make_ccx master_cx in
  let metadata = Context.docblock_overrides docblock options.metadata in
  let module_ref = Reason.OrdinaryName (Files.module_ref filename) in
  let cx = Context.make ccx metadata filename aloc_table module_ref Context.Checking in
  let lint_severities = get_lint_severities metadata options.strict_mode options.lint_severities in

  (* Imports *)
  Type_inference_js.add_require_tvars cx file_sig;
  Context.set_local_env cx file_sig.File_sig.With_ALoc.exported_locals;
  dep_cxs |> Base.List.iter ~f:(Context.merge_into ccx);
  merge_imports cx reqs;

  (* AST inference  *)
  let tast = Type_inference_js.infer_ast cx filename comments ast ~lint_severities in

  (* Post-inference checks *)
  post_merge_checks cx master_cx ast tast metadata file_sig;
  (cx, tast)

(* reduce a context to a "signature context" *)
let sig_context cx module_refs =
  let no_lowers cx r =
    Flow_js_utils.add_output cx (Error_message.EMissingAnnotation (r, []));
    Type.Unsoundness.merged_any r
  in
  let (sig_hash, reducer) = Context_optimizer.reduce_context cx ~no_lowers module_refs in
  Context.set_module_map cx reducer#get_reduced_module_map;
  Context.set_graph cx reducer#get_reduced_graph;
  Context.set_trust_graph cx reducer#get_reduced_trust_graph;
  Context.set_property_maps cx reducer#get_reduced_property_maps;
  Context.set_call_props cx reducer#get_reduced_call_props;
  Context.set_export_maps cx reducer#get_reduced_export_maps;
  Context.set_evaluated cx reducer#get_reduced_evaluated;
  sig_hash

let optimize_builtins cx =
  let reducer =
    let no_lowers _ r = Type.AnyT (r, Type.AnyError (Some Type.UnresolvedName)) in
    new Context_optimizer.context_optimizer ~no_lowers
  in
  let builtins = Context.builtins cx in
  let on_missing name t =
    let reason = TypeUtil.reason_of_t t in
    Flow_js.flow_t cx (Type.AnyT (reason, Type.AnyError (Some Type.UnresolvedName)), t);
    Flow_js.add_output cx (Error_message.EBuiltinLookupFailed { reason; name = Some name })
  in
  Builtins.optimize_entries builtins ~on_missing ~optimize:(reducer#type_ cx Polarity.Neutral);
  Context.set_module_map cx reducer#get_reduced_module_map;
  Context.set_graph cx reducer#get_reduced_graph;
  Context.set_trust_graph cx reducer#get_reduced_trust_graph;
  Context.set_property_maps cx reducer#get_reduced_property_maps;
  Context.set_call_props cx reducer#get_reduced_call_props;
  Context.set_export_maps cx reducer#get_reduced_export_maps;
  Context.set_evaluated cx reducer#get_reduced_evaluated
