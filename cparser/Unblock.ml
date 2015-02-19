(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the GNU General Public License as published by  *)
(*  the Free Software Foundation, either version 2 of the License, or  *)
(*  (at your option) any later version.  This file is also distributed *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(* Simplification of blocks and initializers within functions *)

(* Assumes: nothing
   Produces: unblocked code *)

open C
open Cutil
open Cerrors

(* Convert an initializer to a list of assignment expressions. *)

let rec local_initializer env path init k =
  match init with
  | Init_single e ->
      { edesc = EBinop(Oassign, path, e, path.etyp); etyp = path.etyp } :: k
  | Init_array il ->
      let (ty_elt, sz) =
        match unroll env path.etyp with
        | TArray(ty_elt, Some sz, _) -> (ty_elt, sz)
        | _ -> fatal_error "Wrong type for array initializer" in
      let rec array_init pos il =
        if pos >= sz then k else begin
          let (i1, il') =
            match il with
            | [] -> (default_init env ty_elt, [])
            | i1 :: il' -> (i1, il') in
          local_initializer env
            { edesc = EBinop(Oindex, path, intconst pos IInt, TPtr(ty_elt, []));
              etyp = ty_elt }
            i1
            (array_init (Int64.succ pos) il')
        end in
      array_init 0L il
  | Init_struct(id, fil) ->
      let field_init (fld, i) k =
        local_initializer env
          { edesc = EUnop(Odot fld.fld_name, path); etyp = fld.fld_typ } 
          i k in
      List.fold_right field_init fil k
  | Init_union(id, fld, i) ->
      local_initializer env
        { edesc = EUnop(Odot fld.fld_name, path); etyp = fld.fld_typ }
        i k

(* Prepend assignments to the given statement. *)

let add_inits_stmt loc inits s =
  List.fold_right
    (fun e s -> sseq loc {sdesc = Sdo e; sloc = loc} s)
    inits s

(* Prepend assignments to the given expression. *)
(* Associate to the left so that it prints more nicely *)

let add_inits_expr inits e =
  match inits with
  | [] -> e
  | i1 :: il ->
      let comma a b =
        { edesc = EBinop(Ocomma, a, b, b.etyp); etyp = b.etyp } in
      comma (List.fold_left comma i1 il) e

(* Record new variables to be locally or globally defined *)

let local_variables = ref ([]: decl list)
let global_variables = ref ([]: decl list)

(* Note: "const int x = y - 1;" is legal, but we turn it into 
   "const int x; x = y - 1;", which is not.  Therefore, remove
   top-level 'const' attribute.  Also remove it on element type of
   array type. *)

let remove_const env ty = remove_attributes_type env [AConst] ty

(* Process a compound literal "(ty) { init }".
   At top-level, within an initializer for a global variable,
   it gives rise to a static global definition of a fresh variable,
   initialized with "init".  The compound variable is replaced
   by the fresh variable.
   Within a function, it gives rise to a local variable
   and an explicit initialization at the nearest sequence point. *)

let process_compound_literal islocal env ty init =
  let id = Env.fresh_ident "__compound" in
  if islocal then begin
    let ty' = remove_const env ty in
    let e = {edesc = EVar id; etyp = ty'} in
    local_variables :=
      (Storage_default, id, ty', None) :: !local_variables;
    (local_initializer env e init [], e)
  end else begin
    global_variables :=
      (Storage_static, id, ty, Some init) :: !global_variables;
    ([], {edesc = EVar id; etyp = ty})
  end

(* Elimination of compound literals within an expression.
   Compound literals are turned into fresh variables, recorded in
   [local_variables] or [global_variables] depending on [islocal].
   For local variables, initializing assignments are added before
   the expression and after sequence points in the expression.
   Use only if [e] is a r-value. *)

let rec expand_expr islocal env e =
  let inits = ref [] in   (* accumulator for initializing assignments *)
  let rec expand e =
    match e.edesc with
    | EConst _ | ESizeof _ | EAlignof _ | EVar _ -> e
    | EUnop(op, e1) ->
        {edesc = EUnop(op, expand e1); etyp = e.etyp}
    | EBinop(op, e1, e2, ty) ->
        let e1' = expand e1 in
        let e2' =
          match op with
          | Ocomma | Ologand | Ologor -> expand_expr islocal env e2
              (* Make sure the initializers of [e2] are performed in 
                 sequential order, i.e. just before [e2] but after [e1]. *)
          | _ -> expand e2 in
        {edesc = EBinop(op, e1', e2', ty); etyp = e.etyp}
    | EConditional(e1, e2, e3) ->
        (* Same remark as above: initializers of [e2] and [e3] must
           be performed after the conditional is resolved. *)
        {edesc = EConditional(expand e1,
                              expand_expr islocal env e2,
                              expand_expr islocal env e3);
         etyp = e.etyp}
    | ECast(ty, e1) ->
        {edesc = ECast(ty, expand e1); etyp = e.etyp}
    | ECompound(ty, ie) ->
        let ie' = expand_init islocal env ie in
        let (l, e') = process_compound_literal islocal env ty ie' in
        inits := l @ !inits;
        e'
    | ECall(e1, el) ->
        {edesc = ECall(expand e1, List.map expand el); etyp = e.etyp}
  in 
    let e' = expand e in add_inits_expr !inits e'

(* Elimination of compound literals within an initializer. *)

and expand_init islocal env i =
  let rec expand i =
    match i with
    (* The following "flattening" is not C99.  GCC documents it; whether
       it implements it is unclear.  Clang implements it.  At any rate,
       it makes it possible to use compound literals in static initializers,
       something that is not possible in C99 because compound literals
       are not constant expressions.
       Note that flattening is done for structs and unions but not for
       arrays, because a compound literal of array type in r-value position
       decays to a pointer to its first element. *)
    | Init_single {edesc = ECompound(_, ((Init_struct _ | Init_union _) as i))} ->
        expand i
    | Init_single e ->
        Init_single (expand_expr islocal env e)
    | Init_array il ->
        Init_array (List.map expand il)
    | Init_struct(id, flds) ->
        Init_struct(id, List.map (fun (f, i) -> (f, expand i)) flds)
    | Init_union(id, fld, i) ->
        Init_union(id, fld, expand i)
  in
    expand i

(* Process a block-scoped variable declaration.
   The variable is entered in [local_variables].
   The initializer, if any, is converted into assignments and
   prepended to [k]. *)

let process_decl loc env (sto, id, ty, optinit) k =
  let ty' = remove_const env ty in
  local_variables := (sto, id, ty', None) :: !local_variables;
  match optinit with
  | None -> k
  | Some init ->
      let init' = expand_init true env init in
      let l = local_initializer env { edesc = EVar id; etyp = ty' } init' [] in
      add_inits_stmt loc l k

(* Simplification of blocks within a statement *)

let rec unblock_stmt env s =
  match s.sdesc with
  | Sskip -> s
  | Sdo e ->
      {s with sdesc = Sdo(expand_expr true env e)}
  | Sseq(s1, s2) ->
      {s with sdesc = Sseq(unblock_stmt env s1, unblock_stmt env s2)}
  | Sif(e, s1, s2) -> 
      {s with sdesc = Sif(expand_expr true env e,
                          unblock_stmt env s1, unblock_stmt env s2)}
  | Swhile(e, s1) -> 
      {s with sdesc = Swhile(expand_expr true env e, unblock_stmt env s1)}
  | Sdowhile(s1, e) ->
      {s with sdesc = Sdowhile(unblock_stmt env s1, expand_expr true env e)}
  | Sfor(s1, e, s2, s3) ->
      {s with sdesc = Sfor(unblock_stmt env s1,
                           expand_expr true env e,
                           unblock_stmt env s2,
                           unblock_stmt env s3)}
  | Sbreak -> s
  | Scontinue -> s
  | Sswitch(e, s1) ->
      {s with sdesc = Sswitch(expand_expr true env e, unblock_stmt env s1)}
  | Slabeled(lbl, s1) -> 
      {s with sdesc = Slabeled(lbl, unblock_stmt env s1)}
  | Sgoto lbl -> s
  | Sreturn None -> s
  | Sreturn (Some e) ->
      {s with sdesc = Sreturn(Some (expand_expr true env e))}
  | Sblock sl -> unblock_block env sl
  | Sdecl d -> assert false
  | Sasm _ -> s

and unblock_block env = function
  | [] -> sskip
  | {sdesc = Sdecl d; sloc = loc} :: sl ->
      process_decl loc env d (unblock_block env sl)
  | s :: sl ->
      sseq s.sloc (unblock_stmt env s) (unblock_block env sl)

(* Simplification of blocks and compound literals within a function *)

let unblock_fundef env f =
  local_variables := [];
  let body = unblock_stmt env f.fd_body in
  let decls = !local_variables in
  local_variables := [];
  { f with fd_locals = f.fd_locals @ decls; fd_body = body }

(* Simplification of compound literals within a top-level declaration *)

let unblock_decl loc env ((sto, id, ty, optinit) as d) =
  match optinit with
  | None -> [d]
  | Some init ->
      global_variables := [];
      let init' = expand_init false env init in
      let decls = !global_variables in
      global_variables := [];
      decls @ [(sto, id, ty, Some init')]

(* Unblocking and simplification for whole files.
   The environment is used for typedefs and composites only,
   so we do not maintain variable and function definitions. *)

let rec unblock_glob env accu = function
  | [] -> List.rev accu
  | g :: gl ->
      match g.gdesc with
      | Gdecl((sto, id, ty, init) as d) ->
          let dl = unblock_decl g.gloc env d in
          unblock_glob env
            (List.rev_append
               (List.map (fun d' -> {g with gdesc = Gdecl d'}) dl)
               accu)
            gl
      | Gfundef f ->
          let f' = unblock_fundef env f in
          unblock_glob env ({g with gdesc = Gfundef f'} :: accu) gl
      | Gcompositedecl(su, id, attr) ->
          unblock_glob
            (Env.add_composite env id (composite_info_decl env su attr))
            (g :: accu) gl
      | Gcompositedef(su, id, attr, fl) ->
          unblock_glob
            (Env.add_composite env id (composite_info_def env su attr fl))
            (g :: accu) gl
      | Gtypedef(id, ty) ->
          unblock_glob (Env.add_typedef env id ty) (g :: accu) gl
      | Genumdef (id, attr, members) ->
          unblock_glob
            (Env.add_enum env id {Env.ei_members =  members; Env.ei_attr = attr})
            (g :: accu) gl
      | Gpragma _ ->
          unblock_glob env (g :: accu) gl

(* Entry point *)

let program p =
  unblock_glob (Builtins.environment()) [] p
