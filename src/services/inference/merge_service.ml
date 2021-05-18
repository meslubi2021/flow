(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Utils_js
open Loc_collections
module Reqs = Merge_js.Reqs

type duration = float

type 'a unit_result = ('a, ALoc.t * Error_message.internal_error) result

type merge_result = Error_suppressions.t * duration

type check_type_result =
  Context.t * File_sig.With_ALoc.t * (ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t

type check_error_result =
  Flow_error.ErrorSet.t
  * Flow_error.ErrorSet.t
  * Error_suppressions.t
  * Coverage_response.file_coverage
  * duration

type check_result = check_type_result * check_error_result

type sig_opts_data = {
  skipped_count: int;
  sig_new_or_changed: FilenameSet.t;
}

type 'a merge_results = (File_key.t * bool * 'a unit_result) list * sig_opts_data

type 'a merge_job =
  worker_mutator:Context_heaps.Merge_context_mutator.worker_mutator ->
  options:Options.t ->
  reader:Mutator_state_reader.t ->
  File_key.t Nel.t ->
  bool * 'a unit_result

let scan_for_component_suppressions ~options ~get_ast_unsafe component =
  let lint_severities = Options.lint_severities options in
  let strict_mode = Options.strict_mode options in
  Array.iter
    (fun file ->
      let { Type_sig_merge.key; cx; _ } = file in
      let (_, { Flow_ast.Program.all_comments; _ }) = get_ast_unsafe key in
      let metadata = Context.metadata cx in
      let lint_severities = Merge_js.get_lint_severities metadata strict_mode lint_severities in
      Type_inference_js.scan_for_suppressions cx lint_severities all_comments)
    component

let merge_context ~options ~reader master_cx component =
  let module Pack = Type_sig_pack in
  let module Merge = Type_sig_merge in
  (* make sig context, shared by all file contexts in component *)
  let ccx = Context.make_ccx master_cx in

  (* create per-file contexts *)
  let metadata = Context.metadata_of_options options in
  let create_cx file aloc_table =
    let docblock = Parsing_heaps.Reader_dispatcher.get_docblock_unsafe ~reader file in
    let metadata = Context.docblock_overrides docblock metadata in
    let module_ref = Files.module_ref file in
    Context.make ccx metadata file aloc_table (Reason.OrdinaryName module_ref) Context.Merging
  in

  (* build a reverse lookup, used to detect in-cycle dependencies *)
  let component = Array.of_list (Nel.to_list component) in
  let component_map =
    let acc = ref FilenameMap.empty in
    Array.iteri (fun i file -> acc := FilenameMap.add file i !acc) component;
    !acc
  in

  (* dependencies *)
  let get_leader =
    let cache = Hashtbl.create 0 in
    fun file ->
      match Hashtbl.find_opt cache file with
      | Some leader -> leader
      | None ->
        let leader = Context_heaps.Reader_dispatcher.find_leader ~reader file in
        Hashtbl.add cache file leader;
        leader
  in
  let get_dep_cx =
    let cache = Hashtbl.create 0 in
    fun file ->
      let leader = get_leader file in
      match Hashtbl.find_opt cache leader with
      | Some dep_sig -> dep_sig
      | None ->
        let dep_sig = Context_heaps.Reader_dispatcher.find_sig ~reader leader in
        Context.merge_into ccx dep_sig;
        Hashtbl.add cache leader dep_sig;
        dep_sig
  in
  let mk_builtin_module_t cx mref mname =
    let desc = Reason.RCustom mref in
    let builtin_name = Reason.internal_module_name (Modulename.to_string mname) in
    fun loc ->
      let reason = Reason.mk_reason desc loc in
      Flow_js.lookup_builtin_strict cx builtin_name reason
  in
  let mk_resource_module_t cx filename loc = Import_export.mk_resource_module_t cx loc filename in
  let mk_cyclic_module_t component_rec i _loc =
    let (lazy component) = component_rec in
    let file = component.(i) in
    file.Merge.exports ()
  in
  let mk_acyclic_module_t dep =
    let dep_cx = get_dep_cx dep in
    let dep_exports = Context.find_module_sig dep_cx (Files.module_ref dep) in
    (fun _loc -> dep_exports)
  in
  let mk_legacy_unchecked_module cx mref =
    let desc = Reason.RCustom mref in
    let builtin_name = Reason.internal_module_name mref in
    fun loc ->
      let reason = Reason.(mk_reason desc loc) in
      let default = Type.(AnyT (reason, Untyped)) in
      Flow_js.lookup_builtin_with_default cx builtin_name default
  in
  let file_dependency component_rec cx file_key mref =
    let open Module_heaps in
    let mname = Module_js.find_resolved_module ~reader ~audit:Expensive.ok file_key mref in
    let dep_opt = Reader_dispatcher.get_file ~reader ~audit:Expensive.ok mname in
    let mk_module_t =
      match dep_opt with
      | None -> mk_builtin_module_t cx mref mname
      | Some (File_key.ResourceFile filename) -> mk_resource_module_t cx filename
      | Some dep ->
        let info = Reader_dispatcher.get_info_unsafe ~reader ~audit:Expensive.ok dep in
        if info.checked && info.parsed then
          match FilenameMap.find_opt dep component_map with
          | Some i -> mk_cyclic_module_t component_rec i
          | None -> mk_acyclic_module_t dep
        else
          mk_legacy_unchecked_module cx mref
    in
    (mref, mk_module_t)
  in

  (* read type_sig from heap and create file record for merge *)
  let abstract_locations = Options.abstract_locations options in
  let component_file component_rec file_key =
    let open Type_sig_collections in
    let aloc_table =
      lazy (Parsing_heaps.Reader_dispatcher.get_aloc_table_unsafe ~reader file_key)
    in
    let aloc =
      let source = Some file_key in
      fun (loc : Locs.index) ->
        let aloc = ALoc.ALocRepresentationDoNotUse.make_keyed source (loc :> int) in
        if abstract_locations then
          aloc
        else
          ALoc.of_loc (ALoc.to_loc aloc_table aloc)
    in
    let {
      Packed_type_sig.Module.module_kind;
      module_refs;
      local_defs;
      remote_refs;
      pattern_defs;
      patterns;
    } =
      Parsing_heaps.Reader_dispatcher.get_type_sig_unsafe ~reader file_key
    in
    let cx = create_cx file_key aloc_table in
    let visit_packed file_rec def =
      let def = Pack.map_packed aloc def in
      lazy (Merge.merge (Lazy.force file_rec) def)
    in
    let visit_exports file_rec =
      let merged = ref None in
      let mk_exports reason =
        match module_kind with
        | Pack.CJSModule { type_exports; exports; info } ->
          let (Pack.CJSModuleInfo { type_export_keys; type_stars; strict }) =
            Pack.map_cjs_module_info aloc info
          in
          let type_exports =
            let f acc name export =
              let export =
                lazy
                  ( Pack.map_type_export aloc export
                  |> Merge.merge_type_export (Lazy.force file_rec) reason )
              in
              SMap.add name export acc
            in
            Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
          in
          let exports =
            let f def = lazy (Pack.map_packed aloc def |> Merge.merge (Lazy.force file_rec)) in
            Option.map f exports
          in
          Merge.CJSExports { type_exports; exports; type_stars; strict }
        | Pack.ESModule { type_exports; exports; info } ->
          let (Pack.ESModuleInfo { type_export_keys; export_keys; type_stars; stars; strict }) =
            Pack.map_es_module_info aloc info
          in
          let type_exports =
            let f acc name export =
              let export =
                lazy
                  ( Pack.map_type_export aloc export
                  |> Merge.merge_type_export (Lazy.force file_rec) reason )
              in
              SMap.add name export acc
            in
            Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
          in
          let exports =
            let f acc name export =
              let export =
                lazy (Pack.map_export aloc export |> Merge.merge_export (Lazy.force file_rec))
              in
              SMap.add name export acc
            in
            Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
          in
          Merge.ESExports { type_exports; exports; type_stars; stars; strict }
      in
      fun () ->
        match !merged with
        | Some t -> t
        | None ->
          let file_loc = ALoc.of_loc { Loc.none with Loc.source = Some file_key } in
          let reason = Reason.(mk_reason RExports file_loc) in
          Tvar.mk_where cx reason (fun tvar ->
              merged := Some tvar;
              let exports = mk_exports reason in
              let t = Merge.merge_exports (Lazy.force file_rec) reason exports in
              Flow_js.unify cx tvar t)
    in
    let visit_def file_rec def =
      let merged = ref None in
      let def = Pack.map_packed_def aloc def in
      fun () ->
        let loc = Type_sig.def_id_loc def in
        let name = Type_sig.def_name def in
        let t =
          match !merged with
          | Some t -> t
          | None ->
            let reason = Merge.def_reason def in
            Tvar.mk_where cx reason (fun tvar ->
                merged := Some tvar;
                let t = Merge.merge_def (Lazy.force file_rec) reason def in
                Flow_js.unify cx tvar t)
        in
        (loc, name, t)
    in
    let visit_remote_ref file_rec remote_ref =
      let merged = ref None in
      let remote_ref = Pack.map_remote_ref aloc remote_ref in
      fun () ->
        let loc = Pack.remote_ref_loc remote_ref in
        let name = Pack.remote_ref_name remote_ref in
        let t =
          match !merged with
          | Some t -> t
          | None ->
            let reason = Merge.remote_ref_reason remote_ref in
            Tvar.mk_where cx reason (fun tvar ->
                merged := Some tvar;
                let t = Merge.merge_remote_ref (Lazy.force file_rec) reason remote_ref in
                Flow_js.unify cx tvar t)
        in
        (loc, name, t)
    in
    let visit_pattern file_rec pattern =
      let pattern = Pack.map_pattern aloc pattern in
      lazy (Merge.merge_pattern (Lazy.force file_rec) pattern)
    in
    let dependencies = Module_refs.map (file_dependency component_rec cx file_key) module_refs in
    let rec file_rec =
      lazy
        {
          Merge.key = file_key;
          cx;
          dependencies;
          exports = visit_exports file_rec;
          local_defs = Local_defs.map (visit_def file_rec) local_defs;
          remote_refs = Remote_refs.map (visit_remote_ref file_rec) remote_refs;
          pattern_defs = Pattern_defs.map (visit_packed file_rec) pattern_defs;
          patterns = Patterns.map (visit_pattern file_rec) patterns;
          reposition = (fun loc t -> Flow_js.reposition cx loc t);
          mk_instance = (fun reason t -> Flow_js.mk_instance cx reason t);
          qualify_type =
            (fun reason propname t ->
              let use_op = Type.(Op (GetProperty reason)) in
              Tvar.mk_no_wrap_where cx reason (fun tvar ->
                  Flow_js.flow cx (t, Type.GetPropT (use_op, reason, propname, tvar))));
          export_type =
            (fun reason name t ->
              Tvar.mk_where cx reason (fun tvar ->
                  let name = Reason.OrdinaryName name in
                  Flow_js.flow cx (t, Type.AssertExportIsTypeT (reason, name, tvar))));
        }
    in
    Lazy.force file_rec
  in

  (* create component for merge *)
  let component =
    let rec component_rec = lazy (Array.map (component_file component_rec) component) in
    Lazy.force component_rec
  in

  (* pick out leader/representative cx *)
  let { Merge.cx; _ } = component.(0) in

  (* scan for suppressions *)
  scan_for_component_suppressions
    ~options
    ~get_ast_unsafe:(Parsing_heaps.Reader_dispatcher.get_ast_unsafe ~reader)
    component;

  (* merge *)
  Array.iter Merge.merge_file component;

  cx

let sig_hash ~root =
  let open Type_sig_collections in
  let open Type_sig_hash in
  let module Heap = SharedMem.NewAPI in
  let module P = Type_sig_pack in
  let deserialize x = Marshal.from_string x 0 in

  let hash_file_key file_key =
    let file_string =
      match file_key with
      | File_key.LibFile path
      | File_key.SourceFile path
      | File_key.JsonFile path
      | File_key.ResourceFile path ->
        Files.relative_path (Path.to_string root) path
      | File_key.Builtins -> File_key.to_string file_key
    in
    Xx.hash file_string 0L
  in

  (* The module type of a resource dependency only depends on the file
   * extension. See Import_export.mk_resource_module_t *)
  let resource_dep f =
    let ext =
      match Utils_js.extension_of_filename f with
      | Some ext -> ext
      | None -> failwith "resource file without extension"
    in
    let hash = Xx.hash ext 0L in
    Resource (fun () -> hash)
  in

  (* A dependency which is not part of the cycle has already been merged and its
   * hashes are stored in shared memory. We can create a checked_dep record
   * containing accessors to those hashes.
   *
   * It might be useful to cache this for re-use across files in a component or
   * components in a merge batch, but this performs well enough without caching
   * for now. *)
  let acyclic_dep =
    let type_export addr () = Heap.read_type_export_hash addr in
    let cjs_exports addr () = Heap.read_cjs_exports_hash addr in
    let es_export addr () = Heap.read_es_export_hash addr in
    let cjs_module file_key addr =
      let filename = Fun.const (hash_file_key file_key) in
      let info_addr = Heap.cjs_module_info addr in
      let (P.CJSModuleInfo { type_export_keys; type_stars = _; strict = _ }) =
        Heap.read_cjs_module_info info_addr |> deserialize
      in
      let type_exports =
        let addr = Heap.cjs_module_type_exports addr in
        Heap.read_addr_tbl type_export addr
      in
      let exports =
        let addr = Heap.cjs_module_exports addr in
        Heap.read_opt cjs_exports addr
      in
      let ns () = Heap.read_cjs_module_hash info_addr in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      CJS { filename; type_exports; exports; ns }
    in
    let es_module file_key addr =
      let filename = Fun.const (hash_file_key file_key) in
      let info_addr = Heap.es_module_info addr in
      let (P.ESModuleInfo { type_export_keys; export_keys; type_stars = _; stars = _; strict = _ })
          =
        Heap.read_es_module_info info_addr |> deserialize
      in
      let type_exports =
        let addr = Heap.es_module_type_exports addr in
        Heap.read_addr_tbl type_export addr
      in
      let exports =
        let addr = Heap.es_module_exports addr in
        Heap.read_addr_tbl es_export addr
      in
      let ns () = Heap.read_es_module_hash info_addr in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      let exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
      in
      ES { filename; type_exports; exports; ns }
    in
    fun ~reader dep_key ->
      let file_addr = Parsing_heaps.Reader_dispatcher.get_type_sig_addr_unsafe ~reader dep_key in
      let addr = Heap.file_module file_addr in
      Heap.read_dyn_module (cjs_module dep_key) (es_module dep_key) addr
  in

  (* Create a Type_sig_hash.checked_dep record for a file in the merged component. *)
  let cyclic_dep file_key file_addr file =
    let filename = Fun.const (hash_file_key file_key) in

    let type_export addr =
      let read_hash () = Heap.read_type_export_hash addr in
      let write_hash hash = Heap.write_type_export_hash addr hash in
      let export = Heap.read_type_export addr in
      write_hash (Xx.hash export 0L);
      let export = deserialize export in
      let visit edge _ = visit_type_export edge file export in
      Cycle_hash.create_node visit read_hash write_hash
    in

    let cjs_exports addr =
      let read_hash () = Heap.read_cjs_exports_hash addr in
      let write_hash hash = Heap.write_cjs_exports_hash addr hash in
      let exports = Heap.read_cjs_exports addr in
      write_hash (Xx.hash exports 0L);
      let exports = deserialize exports in
      let visit edge dep_edge = visit_packed edge dep_edge file exports in
      Cycle_hash.create_node visit read_hash write_hash
    in

    let es_export addr =
      let read_hash () = Heap.read_es_export_hash addr in
      let write_hash hash = Heap.write_es_export_hash addr hash in
      let export = Heap.read_es_export addr in
      write_hash (Xx.hash export 0L);
      let export = deserialize export in
      let visit edge dep_edge = visit_export edge dep_edge file export in
      Cycle_hash.create_node visit read_hash write_hash
    in

    let cjs_module addr =
      let info_addr = Heap.cjs_module_info addr in
      let info = Heap.read_cjs_module_info info_addr in
      let (P.CJSModuleInfo { type_export_keys; type_stars; strict = _ }) = deserialize info in
      let type_exports =
        let addr = Heap.cjs_module_type_exports addr in
        Heap.read_addr_tbl type_export addr
      in
      let exports =
        let addr = Heap.cjs_module_exports addr in
        Heap.read_opt cjs_exports addr
      in
      let ns =
        let visit edge dep_edge =
          Array.iter edge type_exports;
          Option.iter edge exports;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) type_stars
        in
        let read_hash () = Heap.read_cjs_module_hash info_addr in
        let write_hash hash = Heap.write_cjs_module_hash info_addr hash in
        write_hash (Xx.hash info 0L);
        Cycle_hash.create_node visit read_hash write_hash
      in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      CJS { filename; type_exports; exports; ns }
    in

    let es_module addr =
      let info_addr = Heap.es_module_info addr in
      let info = Heap.read_es_module_info info_addr in
      let (P.ESModuleInfo { type_export_keys; export_keys; type_stars; stars; strict = _ }) =
        deserialize info
      in
      let type_exports =
        let addr = Heap.es_module_type_exports addr in
        Heap.read_addr_tbl type_export addr
      in
      let exports =
        let addr = Heap.es_module_exports addr in
        Heap.read_addr_tbl es_export addr
      in
      let ns =
        let addr = Heap.es_module_info addr in
        let visit edge dep_edge =
          Array.iter edge type_exports;
          Array.iter edge exports;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) type_stars;
          List.iter (fun (_, index) -> edge_import_ns edge dep_edge file index) stars
        in
        let read_hash () = Heap.read_es_module_hash addr in
        let write_hash hash = Heap.write_es_module_hash addr hash in
        write_hash (Xx.hash info 0L);
        Cycle_hash.create_node visit read_hash write_hash
      in
      let type_exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f type_export_keys type_exports
      in
      let exports =
        let f acc name export = SMap.add name export acc in
        Base.Array.fold2_exn ~init:SMap.empty ~f export_keys exports
      in
      ES { filename; type_exports; exports; ns }
    in

    let addr = Heap.file_module file_addr in
    Heap.read_dyn_module cjs_module es_module addr
  in

  let file_dependency ~reader component_rec component_map file_key mref =
    let open Module_heaps in
    let mname = Module_js.find_resolved_module ~reader ~audit:Expensive.ok file_key mref in
    match Reader_dispatcher.get_file ~reader ~audit:Expensive.ok mname with
    | None -> Unchecked
    | Some (File_key.ResourceFile f) -> resource_dep f
    | Some dep ->
      let info = Reader_dispatcher.get_info_unsafe ~reader ~audit:Expensive.ok dep in
      if info.checked && info.parsed then
        match FilenameMap.find_opt dep component_map with
        | Some i -> Cyclic (lazy (Lazy.force component_rec).(i))
        | None -> Acyclic (lazy (acyclic_dep ~reader dep))
      else
        Unchecked
  in

  (* Create a Type_sig_hash.file record for a file in the merged component. *)
  let component_file ~reader component_rec component_map file_key =
    let file_addr = Parsing_heaps.Reader_dispatcher.get_type_sig_addr_unsafe ~reader file_key in

    let dependencies =
      let f addr =
        let mref = Heap.read_module_ref addr in
        file_dependency ~reader component_rec component_map file_key mref
      in
      let addr = Heap.file_module_refs file_addr in
      Heap.read_addr_tbl_generic f addr Module_refs.init
    in

    let local_defs file_rec =
      let f addr =
        let def = Heap.read_local_def addr in
        let hash = ref (Xx.hash def 0L) in
        let def = deserialize def in
        let visit edge dep_edge = visit_def edge dep_edge (Lazy.force file_rec) def in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let addr = Heap.file_local_defs file_addr in
      Heap.read_addr_tbl_generic f addr Local_defs.init
    in

    let remote_refs file_rec =
      let f addr =
        let remote_ref = Heap.read_remote_ref addr in
        let hash = ref (Xx.hash remote_ref 0L) in
        let remote_ref = deserialize remote_ref in
        let visit edge dep_edge = visit_remote_ref edge dep_edge (Lazy.force file_rec) remote_ref in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let addr = Heap.file_remote_refs file_addr in
      Heap.read_addr_tbl_generic f addr Remote_refs.init
    in

    let pattern_defs file_rec =
      let f addr =
        let def = Heap.read_pattern_def addr in
        let hash = ref (Xx.hash def 0L) in
        let def = deserialize def in
        let visit edge dep_edge = visit_packed edge dep_edge (Lazy.force file_rec) def in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let addr = Heap.file_pattern_defs file_addr in
      Heap.read_addr_tbl_generic f addr Pattern_defs.init
    in

    let patterns file_rec =
      let f addr =
        let pattern = Heap.read_pattern addr in
        let hash = ref (Xx.hash pattern 0L) in
        let pattern = deserialize pattern in
        let visit f _ = visit_pattern f (Lazy.force file_rec) pattern in
        let read_hash () = !hash in
        let write_hash = ( := ) hash in
        Cycle_hash.create_node visit read_hash write_hash
      in
      let addr = Heap.file_patterns file_addr in
      Heap.read_addr_tbl_generic f addr Patterns.init
    in

    let rec file_rec =
      lazy
        {
          dependencies;
          local_defs = local_defs file_rec;
          remote_refs = remote_refs file_rec;
          pattern_defs = pattern_defs file_rec;
          patterns = patterns file_rec;
        }
    in

    cyclic_dep file_key file_addr (Lazy.force file_rec)
  in

  fun ~reader component ->
    (* Built a reverse lookup to detect in-cycle dependencies. *)
    let component = Array.of_list (Nel.to_list component) in
    let component_map =
      let acc = ref FilenameMap.empty in
      Array.iteri (fun i file -> acc := FilenameMap.add file i !acc) component;
      !acc
    in

    (* Create array of Type_sig_hash.checked_dep records, which we can use to
     * traverse the graph of signature dependencies. *)
    let rec component_rec =
      lazy (Array.map (component_file ~reader component_rec component_map) component)
    in

    (* Compute component hash by visiting graph starting at namespace root of
     * each file. The component hash is an unordered combination of each file's
     * hash. *)
    let cx = Cycle_hash.create_cx () in
    let component_hash = ref 0L in
    Array.iter
      (fun (CJS { ns; _ } | ES { ns; _ }) ->
        Cycle_hash.root cx ns;
        let file_hash = Cycle_hash.read_hash ns in
        component_hash := Int64.logxor file_hash !component_hash)
      (Lazy.force component_rec);
    !component_hash

(* Entry point for merging a component *)
let merge_component ~worker_mutator ~options ~reader ((leader_f, _) as component) =
  let start_time = Unix.gettimeofday () in

  (* We choose the head file as the leader, and the tail as followers. It is
   * always OK to choose the head as leader, as explained below.
   *
   * Note that cycles cannot happen between unchecked files. Why? Because files
   * in cycles must have their dependencies recorded, yet dependencies are never
   * recorded for unchecked files.
   *
   * It follows that when the head is unchecked, there are no other files! We
   * don't have to worry that some other file may be checked when the head is
   * unchecked.
   *
   * It also follows when the head is checked, the tail must be checked too! *)
  let info = Module_heaps.Mutator_reader.get_info_unsafe ~reader ~audit:Expensive.ok leader_f in
  if not info.Module_heaps.checked then
    let diff = false in
    (diff, Ok None)
  else if Options.new_check options then
    let hash =
      let reader = Abstract_state_reader.Mutator_state_reader reader in
      let root = Options.root options in
      sig_hash ~root ~reader component
    in
    let metadata = Context.metadata_of_options options in
    let lint_severities = Options.lint_severities options in
    let strict_mode = Options.strict_mode options in
    let ccx = Context.(make_ccx (empty_master_cx ())) in
    let (cx, _) =
      Nel.map
        (fun file ->
          let docblock = Parsing_heaps.Mutator_reader.get_docblock_unsafe ~reader file in
          let metadata = Context.docblock_overrides docblock metadata in
          let lint_severities = Merge_js.get_lint_severities metadata strict_mode lint_severities in
          let aloc_table = lazy (Parsing_heaps.Mutator_reader.get_aloc_table_unsafe ~reader file) in
          let module_ref = Reason.OrdinaryName (Files.module_ref file) in
          let cx = Context.make ccx metadata file aloc_table module_ref Context.Merging in
          let (_, { Flow_ast.Program.all_comments = comments; _ }) =
            Parsing_heaps.Mutator_reader.get_ast_unsafe ~reader file
          in
          Type_inference_js.scan_for_suppressions cx lint_severities comments;
          cx)
        component
    in
    let suppressions = Context.error_suppressions cx in
    let diff =
      Context_heaps.Merge_context_mutator.add_merge_on_diff_no_context worker_mutator component hash
    in
    let duration = Unix.gettimeofday () -. start_time in
    (diff, Ok (Some (suppressions, duration)))
  else
    let reader = Abstract_state_reader.Mutator_state_reader reader in
    let master_cx = Context_heaps.Reader_dispatcher.find_master ~reader in
    let cx = merge_context ~options ~reader master_cx component in
    let suppressions = Context.error_suppressions cx in
    let module_refs = List.rev_map Files.module_ref (Nel.to_list component) in
    let hash = Merge_js.sig_context cx module_refs in
    Context.clear_master_shared cx master_cx;
    let diff =
      Context_heaps.Merge_context_mutator.add_merge_on_diff
        ~audit:Expensive.ok
        worker_mutator
        cx
        component
        hash
    in
    let duration = Unix.gettimeofday () -. start_time in
    (diff, Ok (Some (suppressions, duration)))

let reqs_of_file ~reader required =
  List.fold_left
    (fun (dep_cxs, reqs) (r, locs, resolved_r) ->
      let locs = locs |> Nel.to_list |> ALocSet.of_list in
      let open Module_heaps in
      match Reader_dispatcher.get_file ~reader ~audit:Expensive.ok resolved_r with
      | Some (File_key.ResourceFile f) -> (dep_cxs, Reqs.add_res f locs reqs)
      | Some dep ->
        let info = Reader_dispatcher.get_info_unsafe ~reader ~audit:Expensive.ok dep in
        if info.checked && info.parsed then
          (* checked implementation exists *)
          let m = Files.module_ref dep in
          (* look up impl sig_context *)
          let leader = Context_heaps.Reader_dispatcher.find_leader ~reader dep in
          let dep_cx = Context_heaps.Reader_dispatcher.find_sig ~reader leader in
          (dep_cx :: dep_cxs, Reqs.add_dep_impl m (dep_cx, locs) reqs)
        else
          (* unchecked implementation exists *)
          (dep_cxs, Reqs.add_unchecked r locs reqs)
      | None ->
        (* implementation doesn't exist *)
        (dep_cxs, Reqs.add_decl r (locs, resolved_r) reqs))
    ([], Reqs.empty)
    required

let mk_check_file options ~reader () =
  let get_ast_unsafe file =
    let ((_, { Flow_ast.Program.all_comments; _ }) as ast) =
      Parsing_heaps.Mutator_reader.get_ast_unsafe ~reader file
    in
    let aloc_ast = Ast_loc_utils.loc_to_aloc_mapper#program ast in
    (all_comments, aloc_ast)
  in
  let get_file_sig_unsafe file =
    Parsing_heaps.Mutator_reader.get_file_sig_unsafe ~reader file |> File_sig.abstractify_locs
  in
  let get_aloc_table_unsafe = Parsing_heaps.Mutator_reader.get_aloc_table_unsafe ~reader in
  let get_docblock_unsafe = Parsing_heaps.Mutator_reader.get_docblock_unsafe ~reader in
  let process =
    if Options.new_check options then
      let reader = Abstract_state_reader.Mutator_state_reader reader in
      let cache = New_check_cache.create ~capacity:1000 in
      New_check_service.mk_check_file ~options ~reader ~cache ()
    else
      let options =
        {
          Merge_js.metadata = Context.metadata_of_options options;
          lint_severities = Options.lint_severities options;
          strict_mode = Options.strict_mode options;
        }
      in
      fun file required ->
        let master_cx = Context_heaps.Mutator_reader.find_master ~reader in
        let reader = Abstract_state_reader.Mutator_state_reader reader in
        let (dep_cxs, reqs) = reqs_of_file ~reader required in
        Merge_js.check_file ~options file reqs dep_cxs master_cx
  in
  fun file ->
    let start_time = Unix.gettimeofday () in
    let info = Module_heaps.Mutator_reader.get_info_unsafe ~reader ~audit:Expensive.ok file in
    if info.Module_heaps.checked then
      let (comments, ast) = get_ast_unsafe file in
      let file_sig = get_file_sig_unsafe file in
      let docblock = get_docblock_unsafe file in
      let aloc_table = lazy (get_aloc_table_unsafe file) in
      let requires =
        let require_loc_map = File_sig.With_ALoc.(require_loc_map file_sig.module_sig) in
        let reader = Abstract_state_reader.Mutator_state_reader reader in
        let f mref locs acc =
          let provider = Module_js.find_resolved_module ~reader ~audit:Expensive.ok file mref in
          (mref, locs, provider) :: acc
        in
        SMap.fold f require_loc_map []
      in
      let (cx, typed_ast) = process file requires ast comments file_sig docblock aloc_table in
      let coverage = Coverage.file_coverage ~full_cx:cx typed_ast in
      let errors = Context.errors cx in
      let suppressions = Context.error_suppressions cx in
      let severity_cover = Context.severity_cover cx in
      let include_suppressions = Context.include_suppressions cx in
      let aloc_tables = Context.aloc_tables cx in
      let (errors, warnings, suppressions) =
        Error_suppressions.filter_lints
          ~include_suppressions
          suppressions
          errors
          aloc_tables
          severity_cover
      in
      let duration = Unix.gettimeofday () -. start_time in
      Some ((cx, file_sig, typed_ast), (errors, warnings, suppressions, coverage, duration))
    else
      None

(* Variation of merge_context where requires may not have already been
   resolved. This is used by commands that make up a context on the fly. *)
let check_contents_context ~reader options file ast docblock file_sig =
  let (_, { Flow_ast.Program.all_comments = comments; _ }) = ast in
  let ast = Ast_loc_utils.loc_to_aloc_mapper#program ast in
  let file_sig = File_sig.abstractify_locs file_sig in
  let aloc_table = lazy (Parsing_heaps.Reader.get_aloc_table_unsafe ~reader file) in
  let reader = Abstract_state_reader.State_reader reader in
  let required =
    let require_loc_map = File_sig.With_ALoc.(require_loc_map file_sig.module_sig) in
    let node_modules_containers = !Files.node_modules_containers in
    let f mref ((loc, _) as locs) acc =
      let provider =
        Module_js.imported_module ~options ~reader ~node_modules_containers file loc mref
      in
      (mref, locs, provider) :: acc
    in
    SMap.fold f require_loc_map []
  in
  if Options.new_check options then
    let cache = New_check_cache.create ~capacity:1000 in
    let check_file = New_check_service.mk_check_file ~options ~reader ~cache () in
    check_file file required ast comments file_sig docblock aloc_table
  else
    let options =
      {
        Merge_js.metadata = Context.metadata_of_options options;
        lint_severities = Options.lint_severities options;
        strict_mode = Options.strict_mode options;
      }
    in
    let (dep_cxs, reqs) =
      try reqs_of_file ~reader required with
      | Key_not_found _ -> failwith "not all dependencies are ready yet, aborting..."
      | e -> raise e
    in
    let master_cx = Context_heaps.Reader_dispatcher.find_master ~reader in
    Merge_js.check_file
      ~options
      file
      reqs
      dep_cxs
      master_cx
      ast
      comments
      file_sig
      docblock
      aloc_table

(* Wrap a potentially slow operation with a timer that fires every interval seconds. When it fires,
 * it calls ~on_timer. When the operation finishes, the timer is cancelled *)
let with_async_logging_timer ~interval ~on_timer ~f =
  let start_time = Unix.gettimeofday () in
  let timer = ref None in
  let cancel_timer () = Base.Option.iter ~f:Timer.cancel_timer !timer in
  let rec run_timer ?(first_run = false) () =
    ( if not first_run then
      let run_time = Unix.gettimeofday () -. start_time in
      on_timer run_time );
    timer := Some (Timer.set_timer ~interval ~callback:run_timer)
  in
  (* Timer is unimplemented in Windows. *)
  if not Sys.win32 then run_timer ~first_run:true ();
  let ret =
    try f ()
    with e ->
      cancel_timer ();
      raise e
  in
  cancel_timer ();
  ret

let merge_job ~worker_mutator ~reader ~job ~options merged elements =
  List.fold_left
    (fun merged -> function
      | Merge_stream.Component ((leader, _) as component) ->
        (* A component may have several files: there's always at least one, and
           multiple files indicate a cycle. *)
        let files =
          component |> Nel.to_list |> Base.List.map ~f:File_key.to_string |> String.concat "\n\t"
        in
        let merge_timeout = Options.merge_timeout options in
        let interval = Base.Option.value_map ~f:(min 15.0) ~default:15.0 merge_timeout in
        (try
           with_async_logging_timer
             ~interval
             ~on_timer:(fun run_time ->
               Hh_logger.info
                 "[%d] Slow MERGE (%f seconds so far): %s"
                 (Unix.getpid ())
                 run_time
                 files;
               Base.Option.iter merge_timeout ~f:(fun merge_timeout ->
                   if run_time >= merge_timeout then
                     raise (Error_message.EMergeTimeout (run_time, files))))
             ~f:(fun () ->
               let start_time = Unix.gettimeofday () in
               (* prerr_endlinef "[%d] MERGE: %s" (Unix.getpid()) files; *)
               let (diff, result) = job ~worker_mutator ~options ~reader component in
               let merge_time = Unix.gettimeofday () -. start_time in
               if Options.should_profile options then (
                 let length = Nel.length component in
                 let leader = File_key.to_string leader in
                 Flow_server_profile.merge ~length ~merge_time ~leader;
                 if merge_time > 1.0 then
                   Hh_logger.info "[%d] perf: merged %s in %f" (Unix.getpid ()) files merge_time
               );
               (leader, diff, result) :: merged)
         with
        | (SharedMem.Out_of_shared_memory | SharedMem.Heap_full | SharedMem.Hash_table_full) as exc
          ->
          raise exc
        (* A catch all suppression is probably a bad idea... *)
        | unwrapped_exc ->
          let exc = Exception.wrap unwrapped_exc in
          let exn_str = Printf.sprintf "%s: %s" files (Exception.to_string exc) in
          (* Ensure heaps are in a good state before continuing. *)
          let diff =
            Context_heaps.Merge_context_mutator.add_merge_on_exn
              ~audit:Expensive.ok
              ~options
              worker_mutator
              component
          in

          (* In dev mode, fail hard, but log and continue in prod. *)
          if Build_mode.dev then
            Exception.reraise exc
          else
            prerr_endlinef
              "(%d) merge_job THROWS: [%d] %s\n"
              (Unix.getpid ())
              (Nel.length component)
              exn_str;

          (* An errored component is always changed. *)
          let file_loc = Loc.{ none with source = Some leader } |> ALoc.of_loc in
          (* We can't pattern match on the exception type once it's marshalled
             back to the master process, so we pattern match on it here to create
             an error result. *)
          let result =
            Error
              Error_message.(
                match unwrapped_exc with
                | EDebugThrow loc -> (loc, DebugThrow)
                | EMergeTimeout (s, _) -> (file_loc, MergeTimeout s)
                | _ -> (file_loc, MergeJobException exc))
          in
          (leader, diff, result) :: merged))
    merged
    elements

let merge_runner
    ~job
    ~master_mutator
    ~worker_mutator
    ~reader
    ~options
    ~workers
    ~sig_dependency_graph
    ~component_map
    ~recheck_set =
  let num_workers = Options.max_workers options in
  (* (1) make a map from files to their component leaders
     (2) lift recheck set from files to their component leaders *)
  let (leader_map, recheck_leader_set) =
    FilenameMap.fold
      (fun leader component (leader_map, recheck_leader_set) ->
        let (leader_map, recheck_leader) =
          Nel.fold_left
            (fun (leader_map, recheck_leader) file ->
              ( FilenameMap.add file leader leader_map,
                recheck_leader || FilenameSet.mem file recheck_set ))
            (leader_map, false)
            component
        in
        let recheck_leader_set =
          if recheck_leader then
            FilenameSet.add leader recheck_leader_set
          else
            recheck_leader_set
        in
        (leader_map, recheck_leader_set))
      component_map
      (FilenameMap.empty, FilenameSet.empty)
  in
  let start_time = Unix.gettimeofday () in
  let stream =
    Merge_stream.create
      ~num_workers
      ~reader
      ~sig_dependency_graph
      ~leader_map
      ~component_map
      ~recheck_leader_set
  in
  Merge_stream.update_server_status stream;

  (* returns parallel lists of filenames, error sets, and suppression sets *)
  let%lwt ret =
    MultiWorkerLwt.call
      workers
      ~job:(merge_job ~worker_mutator ~reader ~options ~job)
      ~neutral:[]
      ~merge:(Merge_stream.merge ~master_mutator stream)
      ~next:(Merge_stream.next stream)
  in
  let total_files = Merge_stream.total_files stream in
  let skipped_count = Merge_stream.skipped_count stream in
  let sig_new_or_changed = Merge_stream.sig_new_or_changed stream in
  Hh_logger.info "Merge skipped %d of %d modules" skipped_count total_files;
  let elapsed = Unix.gettimeofday () -. start_time in
  if Options.should_profile options then Hh_logger.info "merged in %f" elapsed;
  Lwt.return (ret, { skipped_count; sig_new_or_changed })

let merge = merge_runner ~job:merge_component

let mk_check options ~reader () =
  let check_timeout = Options.merge_timeout options in
  (* TODO: add new option *)
  let interval = Base.Option.value_map ~f:(min 5.0) ~default:5.0 check_timeout in
  let check_file = mk_check_file options ~reader () in
  fun file ->
    let file_str = File_key.to_string file in
    try
      with_async_logging_timer
        ~interval
        ~on_timer:(fun run_time ->
          Hh_logger.info
            "[%d] Slow CHECK (%f seconds so far): %s"
            (Unix.getpid ())
            run_time
            file_str;
          Base.Option.iter check_timeout ~f:(fun check_timeout ->
              if run_time >= check_timeout then
                raise (Error_message.ECheckTimeout (run_time, file_str))))
        ~f:(fun () -> Ok (check_file file))
    with
    | (SharedMem.Out_of_shared_memory | SharedMem.Heap_full | SharedMem.Hash_table_full) as exc ->
      raise exc
    (* A catch all suppression is probably a bad idea... *)
    | unwrapped_exc ->
      let exc = Exception.wrap unwrapped_exc in
      let exn_str = Printf.sprintf "%s: %s" (File_key.to_string file) (Exception.to_string exc) in
      (* In dev mode, fail hard, but log and continue in prod. *)
      if Build_mode.dev then
        Exception.reraise exc
      else
        prerr_endlinef "(%d) check_job THROWS: %s\n" (Unix.getpid ()) exn_str;
      let file_loc = Loc.{ none with source = Some file } |> ALoc.of_loc in
      (* We can't pattern match on the exception type once it's marshalled
         back to the master process, so we pattern match on it here to create
         an error result. *)
      Error
        Error_message.(
          match unwrapped_exc with
          | EDebugThrow loc -> (loc, DebugThrow)
          | ECheckTimeout (s, _) -> (file_loc, CheckTimeout s)
          | _ -> (file_loc, CheckJobException exc))
