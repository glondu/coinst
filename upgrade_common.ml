(* Co-installability tools
 * http://coinst.irill.org/
 * Copyright (C) 2005-2011 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * These programs are free software; you can redistribute them and/or
 * modify them under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)

let debug_coinst =
  Debug.make "coinst" "Debug co-installability issue analyse" []
let debug_time = Debug.make "time" "Print execution times" []
let debug_cluster = Debug.make "cluster" "Debug clustering algorithm" []
let debug_problems =
  Debug.make "coinst_prob"
    "Debug enumeration of possible co-installability issues" []
let debug_problem_graph =
  Debug.make "coinst_graph"
    "Write the graph of new depencies to /tmp/newdeps.dot" []

let debug = false

module IntSet = Util.IntSet
module StringSet = Util.StringSet

module M = Deb_lib
module Coinst = Coinst_common.F(M)
module Repository = Coinst.Repository
open Repository
module Quotient = Coinst.Quotient
module Graph = Graph.F (Coinst.Repository)

module PSetSet = Set.Make (PSet)
module PSetMap = Map.Make (PSet)

module Timer = Util.Timer

(****)

let new_deps pred deps1 dist2 deps2 =
  PTbl.mapi
    (fun p2 i ->
       if i = -1 then
         Formula._true
       else begin
         let p1 = Package.of_index i in
         let f1 = PTbl.get deps1 p1 in
         let f2 = PTbl.get deps2 p2 in

         let f2 =
           Formula.filter
             (fun d2 ->
                let d1 =
                  Disj.fold
                    (fun p2 d2 ->
                       let i = PTbl.get pred p2 in
                       if i = -1 then d2 else
                       Disj.disj (Disj.lit (Package.of_index i)) d2)
                    d2 Disj._false
                in
                not (Formula.implies1 f1 d1))
             f2
         in
  if debug && not (Formula.implies Formula._true f2) then begin
  Format.printf "%a ==> %a@."
   (Package.print_name dist2) p2
   (Formula.print dist2) f2;
  (*
  Format.printf "%a --> %a@."
   (Package.print_name dist1) p1
   (Formula.print dist1) f1
  *)
  end;
         f2
       end)
    pred

(****)

module ListTbl = Util.ListTbl

type st =
  { dist : M.pool; deps : Formula.t PTbl.t; confl : Conflict.t;
    pieces : (int, Package.t * Disj.t) Hashtbl.t;
    pieces_in_confl : (Package.t, int) ListTbl.t;
    set : PSet.t;
    installed : IntSet.t; not_installed : IntSet.t;
    check : PSet.t -> bool }

let print_prob st =
  IntSet.iter
    (fun i ->
       let (p, d) = Hashtbl.find st.pieces i in
       Format.printf "%a => %a; "
         (Package.print_name st.dist) p
         (Disj.print st.dist) d)
    st.installed;
  Format.printf "@."

let rec add_piece st i cont =
  assert (not (IntSet.mem i st.installed || IntSet.mem i st.not_installed));
  let (p, d) = Hashtbl.find st.pieces i in
  if
    (* We do not add a dependency if it is implied by, or implies, a
       dependency currently under consideration. *)
    not (IntSet.exists
           (fun i' ->
              let (_, d') = Hashtbl.find st.pieces i' in
              Disj.implies d d' || Disj.implies d' d)
           st.installed)
      &&
    (* When adding a package in st.set, we check that d is not implied
       by any of the dependencies of a package already in st.set *)
    (PSet.mem p st.set ||
     not (PSet.exists
            (fun p -> Formula.implies (PTbl.get st.deps p) (Formula.of_disj d))
            st.set))
      &&
    (* If we are adding a package, we check whether the set is still
       co-installable *)
    (PSet.mem p st.set || st.check (PSet.add p st.set))
  then begin
    if debug_problems () then
      Format.printf "Adding %a => %a@."
        (Package.print_name st.dist) p (Disj.print st.dist) d;
    let st =
      {st with set = PSet.add p st.set;
       installed = IntSet.add i st.installed}
    in
    if debug_problems () then print_prob st;
    (* Make sure that there is at least one piece in conflict for all
       dependencies, then consider all possible additions *)
    Disj.fold
      (fun p cont st ->
         if
           PSet.exists
             (fun q ->
                List.exists (fun i -> IntSet.mem i st.installed)
                  (ListTbl.find st.pieces_in_confl q))
             (Conflict.of_package st.confl p)
         then
           cont st
         else
           ignore
             (PSet.fold
                (fun q st ->
                   List.fold_right (fun j st -> do_add_piece st j cont)
                     (ListTbl.find st.pieces_in_confl q) st)
                (Conflict.of_package st.confl p) st))
      d
      (fun st ->
         if debug_problems () then
           Format.printf "Considering all possible additions in %d: %a...@."
             i (Disj.print st.dist) d;
        Disj.fold
         (fun p cont ->
            PSet.fold
              (fun q cont ->
                 List.fold_right (fun j cont st -> maybe_add_piece st j cont)
                   (ListTbl.find st.pieces_in_confl q) cont)
              (Conflict.of_package st.confl p) cont)
           d cont st)
      st
  end else
    if debug_problems () then
      Format.printf "Could not add %a => %a@."
        (Package.print_name st.dist) p (Disj.print st.dist) d;


and do_add_piece st i cont =
  if IntSet.mem i st.installed then begin
    cont st; st
  end else if not (IntSet.mem i st.not_installed) then begin
    add_piece st i cont;
    {st with not_installed = IntSet.add i st.not_installed}
  end else
    st

and maybe_add_piece st i cont =
  if
    not (IntSet.mem i st.installed || IntSet.mem i st.not_installed)
  then begin
    add_piece st i cont;
    cont {st with not_installed = IntSet.add i st.not_installed}
  end else
    cont st

let find_problems dist deps confl check =
  let pieces = Hashtbl.create 101 in
  let last_piece = ref (-1) in
  let pieces_in_confl = ListTbl.create 101 in
  PTbl.iteri
    (fun p f ->
      Formula.iter f
        (fun d ->
          incr last_piece;
          let i = !last_piece in
          Hashtbl.add pieces i (p, d);
          Disj.iter d (fun p -> ListTbl.add pieces_in_confl p i)))
    deps;
  let st =
    { dist = dist; deps = deps; confl = confl;
      pieces = pieces; pieces_in_confl = pieces_in_confl;
      set = PSet.empty; check = check;
      installed = IntSet.empty; not_installed = IntSet.empty }
  in
  for i = 0 to !last_piece do
    add_piece st i (fun _ -> ())
  done

(****)

type state =
  { dist : M.deb_pool;
    deps : Formula.t PTbl.t;
    confl : Conflict.t;
    deps' : Formula.t PTbl.t;
    confl' : Conflict.t;
    st : M.Solver.state }

(****)

type pkg_ref = string * bool * bool
type reason =
    R_depends of pkg_ref * M.dep * pkg_ref list
  | R_conflict of pkg_ref * M.dep * pkg_ref
type clause = { pos : StringSet.t; neg : StringSet.t }

let problematic_packages dist1 dist dist2 reasons =
  let resolve_dep dist l =
    List.fold_left
      (fun s cstr ->
         List.fold_left
           (fun s p -> StringSet.add p.M.package s)
           s (M.resolve_package_dep_raw dist cstr))
      StringSet.empty l
  in
  let (s1, s2, lst) =
    List.fold_left
      (fun (s1, s2, lst) r ->
         match r with
           M.R_depends (n, l) ->
             let p = Hashtbl.find dist.M.packages_by_num n in
             let nm = p.M.package in
             let d = resolve_dep dist l in
             let d1 = resolve_dep dist1 l in
             let d2 = resolve_dep dist2 l in
             let s1 = StringSet.union (StringSet.diff d1 d) s1 in
             let s2 = StringSet.union (StringSet.diff d2 d) s2 in
             let unchanged_dep dist =
               match ListTbl.find dist.M.packages_by_name nm with
                 [] ->
                   false
               | [q] ->
                   M.compare_version q.M.version p.M.version = 0
                     ||
                   List.exists
                     (fun l' ->
                        let d1' = resolve_dep dist1 l' in
                        StringSet.subset d1' d1
                          &&
                        let d2' = resolve_dep dist2 l' in
                        StringSet.subset d2' d2)
                     (q.M.pre_depends @ q.M.depends)
               | _ ->
                   assert false
             in
             let u1 = unchanged_dep dist1 in
             let u2 = unchanged_dep dist2 in
             let s1 = if u1 then s1 else StringSet.add nm s1 in
             let s2 = if u2 then s2 else StringSet.add nm s2 in
             let pkgs =
               List.map
                 (fun nm -> (nm, StringSet.mem nm d1, StringSet.mem nm d2))
                 (StringSet.elements (StringSet.union d1 d2))
             in
             (s1, s2, R_depends ((nm, u1, u2), l, pkgs) :: lst)
         | M.R_conflict (j, k, Some (i, l)) ->
             let i' = if i = j then k else j in
             let p = Hashtbl.find dist.M.packages_by_num i in
             let p' = Hashtbl.find dist.M.packages_by_num i' in
             let nm = p.M.package in
             let nm' = p'.M.package in
             let c1 = resolve_dep dist1 l in
             let c2 = resolve_dep dist2 l in
             let u1' = StringSet.mem nm' c1 in
             let s1 = if u1' then s1 else StringSet.add nm' s1 in
             let u2' = StringSet.mem nm' c2 in
             let s2 = if u2' then s2 else StringSet.add nm' s2 in
             let unchanged_cfl dist =
               match ListTbl.find dist.M.packages_by_name nm with
                 [] ->
                   false
               | [q] ->
                   M.compare_version q.M.version p.M.version = 0
                     ||
                   (let l' = List.flatten (q.M.breaks @ q.M.conflicts) in
                    StringSet.mem nm' (resolve_dep dist1 l')
                      &&
                    StringSet.mem nm' (resolve_dep dist2 l'))
               | _ ->
                   assert false
             in
             let u1 = unchanged_cfl dist1 in
             let u2 = unchanged_cfl dist2 in
             let s1 = if u1 then s1 else StringSet.add nm s1 in
             let s2 = if u2 then s2 else StringSet.add nm s2 in
             (s1, s2, R_conflict ((nm, u1, u2), l, (nm', u1', u2')) :: lst)
         | M.R_conflict (_, _, None) ->
             assert false)
      (StringSet.empty, StringSet.empty, []) reasons
  in
  ({pos = s1; neg = s2}, List.rev lst)

(*
let problematic_packages dist1 dist dist2 reasons =
  let resolve_dep dist l =
    List.fold_left
      (fun s cstr ->
         List.fold_left
           (fun s p -> StringSet.add p.M.package s)
           s (M.resolve_package_dep_raw dist cstr))
      StringSet.empty l
  in
  List.fold_left
    (fun s r ->
       match r with
         M.R_depends (n, l) ->
           let p = Hashtbl.find dist.M.packages_by_num n in
           let nm = p.M.package in
           let d = resolve_dep dist l in
           let d1 = resolve_dep dist1 l in
           let s = StringSet.union (StringSet.diff d1 d) s in 
           begin match ListTbl.find dist1.M.packages_by_name nm with
             [] ->
               StringSet.add nm s
           | [p1] ->
               if
                 M.compare_version p1.M.version p.M.version = 0
                   ||
                 let d2 = resolve_dep dist2 l in
                 List.exists
                   (fun l' ->
                      let d1' = resolve_dep dist1 l' in
                      StringSet.subset d1' d1
                        &&
                      let d2' = resolve_dep dist2 l' in
                      StringSet.subset d2' d2)
                   (p1.M.pre_depends @ p1.M.depends)
               then
                 s
               else
                 StringSet.add nm s
           | _ ->
               assert false
           end
       | M.R_conflict (j, k, Some (i, l)) ->
           let i' = if i = j then k else j in
           let p = Hashtbl.find dist.M.packages_by_num i in
           let p' = Hashtbl.find dist.M.packages_by_num i' in
           let nm = p.M.package in
           let nm' = p'.M.package in
           let c1 = resolve_dep dist1 l in
           let s = if StringSet.mem nm' c1 then s else StringSet.add nm' s in
           begin match ListTbl.find dist1.M.packages_by_name nm with
             [] ->
               StringSet.add nm s
           | [p1] ->
               if
                 M.compare_version p1.M.version p.M.version = 0
                   ||
                 (let l' = List.flatten (p1.M.breaks @ p1.M.conflicts) in
                  StringSet.mem nm' (resolve_dep dist1 l')
                    &&
                  StringSet.mem nm' (resolve_dep dist2 l'))
               then
                 s
               else
                 StringSet.add nm s
           | _ ->
               assert false
           end
       | M.R_conflict (_, _, None) ->
           assert false)
    StringSet.empty reasons
*)

(****)

type graph =
  { g_nodes : PSet.t; g_deps : Formula.t PTbl.t; g_confl : Conflict.t }
type issue =
  { i_issue : PSet.t; i_clause : clause;
    i_graph : graph; i_explain : reason list }

let print_clause ch clause =
  Util.print_list (fun f -> Format.fprintf f "-%s") " | " ch
    (StringSet.elements clause.neg);
  if not (StringSet.is_empty clause.pos || StringSet.is_empty clause.neg) then
    Format.fprintf ch " | ";
  Util.print_list (fun f -> Format.fprintf f "%s") " | " ch
    (StringSet.elements clause.pos)

let prepare_analyze dist =
  let (deps, confl) = Coinst.compute_dependencies_and_conflicts dist in
  let (deps', confl') = Coinst.flatten_and_simplify dist deps confl in
  let st = Coinst.generate_rules (Quotient.trivial dist) deps' confl' in
  { dist=dist; deps=deps; confl=confl; deps'=deps'; confl'=confl'; st=st }

let compute_predecessors dist1 dist2 =
  PTbl.init dist2
    (fun p2 ->
       let nm = M.package_name dist2 (Package.index p2) in
       match M.parse_package_name dist1 nm with
         [] ->
           if debug then Format.printf "%s is a new package@." nm;
           -1
       | [p1] ->
           p1
       | _ ->
           assert false)

let analyze ?(check_new_packages = false) ?reference dist1_state dist2 =
  let
    { dist = dist1; deps = deps1; confl = confl1;
      deps' = deps1'; confl' = confl1'; st = st1 }
    = dist1_state
  in
  let t = Timer.start () in
  let t' = Timer.start () in
  let (deps2, confl2) = Coinst.compute_dependencies_and_conflicts dist2 in
  if debug_time () then
    Format.eprintf "    Deps and confls: %f@." (Timer.stop t');
  let (deps2', confl2') = Coinst.flatten_and_simplify dist2 deps2 confl2 in
  let t' = Timer.start () in
  let st2 = Coinst.generate_rules (Quotient.trivial dist2) deps2' confl2' in
  if debug_time () then begin
    Format.eprintf "    Rules: %f@." (Timer.stop t');
    Format.eprintf "  Target dist: %f@." (Timer.stop t)
  end;

  let t = Timer.start () in
  let pred = compute_predecessors dist1 dist2 in

  let new_conflicts = ref [] in
  Conflict.iter confl2
    (fun p2 q2 ->
       let i = PTbl.get pred p2 in
       let j = PTbl.get pred q2 in
       if i <> -1 && j <> -1 then begin
         let p1 = Package.of_index i in
         let q1 = Package.of_index j in
         if not (Conflict.check confl1 p1 q1) then begin
           if debug_coinst () then begin
             Format.eprintf "possible new conflict: %a %a@."
               (Package.print_name dist1) p1
               (Package.print_name dist1) q1;
           end;
           new_conflicts := (p2, q2) :: !new_conflicts;
         end
       end);

  let results = ref PSetSet.empty in
  let add_result s =
    if not (PSetSet.mem s !results) then begin
      if debug_coinst () then begin
        Format.eprintf "==>";
        PSet.iter
          (fun p -> Format.eprintf " %a" (Package.print_name dist2) p) s;
        Format.eprintf "@."
      end;
      results := PSetSet.add s !results
    end
  in

  let is_installable p =
    let res = M.Solver.solve st2 (Package.index p) in
    M.Solver.reset st2;
    res
  and was_installable p =
    let res = M.Solver.solve st1 (PTbl.get pred p) in
    M.Solver.reset st1;
    res
  in
  (*
  (* Clearly non installable packages *)
  PTbl.iteri
    (fun p f ->
       if
         PTbl.get pred p <> -1 &&
         Formula.implies f Formula._false && was_installable p
       then
         add_result (PSet.singleton p))
    deps2';
  *)
  (* New conflict pairs *)
  List.iter
    (fun (p2, q2) ->
       let pi = is_installable p2 in
       let qi = is_installable q2 in
       if not pi && was_installable p2 then add_result (PSet.singleton p2);
       if not qi && was_installable q2 then add_result (PSet.singleton q2);
       if pi && qi then begin
         let i = PTbl.get pred p2 in
         let j = PTbl.get pred q2 in
         let p1 = Package.of_index i in
         let q1 = Package.of_index j in
         if M.Solver.solve_lst st1 [i; j] then begin
  if debug then begin
           Format.printf "new conflict: %a %a@."
             (Package.print_name dist1) p1
             (Package.print_name dist1) q1;
  end;
           add_result (PSet.add p2 (PSet.add q2 PSet.empty))
         end else begin
  if debug then begin
           Format.printf "NOT new conflict: %a %a@."
             (Package.print_name dist1) p1
             (Package.print_name dist1) q1;
           M.show_reasons dist1 (M.Solver.collect_reasons_lst st1 [i; j])
  end
         end;
         M.Solver.reset st1
       end)
    !new_conflicts;

  (* Only consider new dependencies. *)
  let deps2 = new_deps pred deps1 dist2 deps2 in
  (* Compute the corresponding flattened dependencies. *)
  let deps2 =
    PTbl.mapi
       (fun p f ->
          Formula.fold
            (fun d f ->
               Formula.conj
                 (PSet.fold
                    (fun p f -> Formula.disj (PTbl.get deps2' p) f)
                    (Disj.to_lits d) Formula._false) f)
            f Formula._true)
      deps2
  in
  (* Only keep those that are new... *)
  let deps2 = new_deps pred deps1' dist2 deps2 in
  (* ...and that are indeed in the flattened repository *)
  let deps2 =
    PTbl.mapi
      (fun p f ->
         let f' = PTbl.get deps2' p in
         Formula.filter
           (fun d ->
              Formula.exists (fun d' -> Disj.equiv d d') f') f)
      deps2
  in

  (* Only keep relevant conflicts. *)
  let dep_targets = ref PSet.empty in
  PTbl.iteri
    (fun _ f ->
       Formula.iter f
         (fun d ->
            Disj.iter d (fun p -> dep_targets := PSet.add p !dep_targets)))
    deps2;
  Conflict.iter confl2'
    (fun p2 q2 ->
       let i1 = PTbl.get pred p2 in
       let j1 = PTbl.get pred q2 in
       if
         not ((PSet.mem p2 !dep_targets && j1 <> -1) ||
              (PSet.mem q2 !dep_targets && i1 <> -1) ||
              (PSet.mem p2 !dep_targets && PSet.mem q2 !dep_targets))
       then
         Conflict.remove confl2' p2 q2);
  List.iter (fun (p2, q2) -> Conflict.remove confl2' p2 q2) !new_conflicts;
  (* As a consequence, some new dependencies might not be relevant anymore. *)
  let deps2 = Coinst.remove_irrelevant_deps confl2' deps2 in

  (* Add self dependencies for packages with conflicts, as we want to
     consider them as well to find possible problems. *)
  let deps2 =
    PTbl.mapi
      (fun p f ->
         if Conflict.has confl2' p && PTbl.get pred p <> -1 then
           Formula.conj (Formula.lit p) f
         else
           f)
      deps2
  in

  if debug_problem_graph () then
    Graph.output "/tmp/newdeps.dot"
      ~package_weight:(fun p ->
        if Formula.implies (Formula.lit p) (PTbl.get deps2 p) then
          (if PTbl.get pred p = -1 then 1. else 10.)
        else 1000.)
      (Quotient.trivial dist2) deps2 confl2';

  if debug_time () then Format.eprintf "  Init: %f@." (Timer.stop t);

  let check s =
    let now_installable s =
      let res =
        M.Solver.solve_lst st2 (List.map Package.index (PSet.elements s)) in
      M.Solver.reset st2;
      res
    in
    let l = PSet.elements s in
    let was_coinstallable =
      M.Solver.solve_lst st1 (List.map (fun p -> PTbl.get pred p) l)
    in
    M.Solver.reset st1;
    if not was_coinstallable then begin
  if debug then begin
  Format.printf "Was not co-installable:";
  List.iter (fun p -> Format.printf " %a" (Package.print_name dist2) p) l;
  Format.printf "@.";
  end;
      false
    end else if now_installable s then begin
  if debug then begin
  Format.printf "Still co-installable:";
  List.iter (fun p -> Format.printf " %a" (Package.print_name dist2) p) l;
  Format.printf "@.";
  end;
      true
    end else begin
      if
        PSet.exists (fun p -> not (now_installable (PSet.remove p s))) s
      then begin
  if debug_coinst () then begin
  Format.eprintf "Not minimal:";
  List.iter (fun p -> Format.eprintf " %a" (Package.print_name dist2) p) l;
  Format.eprintf "@.";
  end;
      end else begin
        add_result s
      end;
      false
    end
  in
  let t = Timer.start () in
  find_problems dist2 deps2 confl2' check;
  if debug_time () then
    Format.eprintf "  Enumerating problems: %f@." (Timer.stop t);

  (****)

  let t = Timer.start () in
  let all_pkgs = ref PSet.empty in
  let all_conflicts = Conflict.create dist2 in
  let dep_src = PTbl.create dist2 PSet.empty in
  let dep_trg = PTbl.create dist2 PSet.empty in
  let add_rel r p q = PTbl.set r p (PSet.add q (PTbl.get r p)) in

  let broken_new_packages = ref PSet.empty in
  if check_new_packages then begin
    PTbl.iteri
      (fun p _ ->
         if PTbl.get pred p = -1 then begin
(*Format.eprintf "??? %a@." (Package.print dist2) p;*)
           if not (M.Solver.solve st2 (Package.index p)) then begin
(*
             M.Solver.solve st2init (Package.index p);
             M.Solver.reset st2init;
*)
             broken_new_packages := PSet.add p !broken_new_packages
           end;
           M.Solver.reset st2
         end)
      deps2
  end;

  let (graphs, broken_new_packages) =
    if PSetSet.is_empty !results && PSet.is_empty !broken_new_packages then
      ([], [])
    else begin
      let s = PSetSet.fold PSet.union !results !broken_new_packages in
      let t = Timer.start () in
      let st2init = M.generate_rules_restricted dist2 (pset_indices s) in
      if debug_time () then
        Format.eprintf "    Generating constraints: %f@." (Timer.stop t);
      (List.map
         (fun s ->
            let l = List.map Package.index (PSet.elements s) in
            let res = M.Solver.solve_lst st2init l in
            assert (not res);
            let r = M.Solver.collect_reasons_lst st2init l in
            M.Solver.reset st2init;
            let confl = Conflict.create dist2 in
            let deps = PTbl.create dist2 Formula._true in
            let pkgs = ref PSet.empty in
            let package i =
              let p = Package.of_index i in pkgs := PSet.add p !pkgs; p in
(*
if debug_coinst () then M.show_reasons dist2 r;
*)
            List.iter
              (fun r ->
                 match r with
                   M.R_conflict (n1, n2, _) ->
                     Conflict.add confl (package n1) (package n2);
                     Conflict.add all_conflicts (package n1) (package n2)
                 | M.R_depends (n, l) ->
                     let p = package n in
                     let l =
                       List.map package
                         (List.flatten
                            (List.map (M.resolve_package_dep dist2) l))
                     in
                     List.iter
                       (fun q ->
                          add_rel dep_src q p;
                          add_rel dep_trg p q)
                       l;
                     PTbl.set deps p
                       (Formula.conj (PTbl.get deps p)
                          (Formula.of_disj (Disj.lit_disj l))))
              r;
            all_pkgs := PSet.union !all_pkgs !pkgs;
            let (clause, explanation) =
              match reference with
                Some dist2_state ->
                  problematic_packages
                    dist1_state.dist dist2 dist2_state.dist r
              | None ->
                  problematic_packages dist1_state.dist dist2 dist2 r
            in
 (*
 PSet.iter (fun p -> Format.printf " %a" (Package.print_name dist2) p) s;
 Format.printf "==> %a@." (Formula.print dist1) ppkgs;
 *)
            { i_issue = s; i_clause = clause;
              i_graph = { g_nodes = !pkgs; g_deps = deps; g_confl = confl };
              i_explain = explanation })
         (PSetSet.elements !results),
       PSet.fold
         (fun p s ->
            let i = Package.index p in
            let res = M.Solver.solve st2init i in
            assert (not res);
            let r = M.Solver.collect_reasons st2init i in
            M.Solver.reset st2init;
(*
if debug_coinst () then M.show_reasons dist2 r;
*)
            let (clause, explanation) =
              match reference with
                Some dist2_state ->
                  problematic_packages
                    dist1_state.dist dist2 dist2_state.dist r
              | None ->
                  problematic_packages dist1_state.dist dist2 dist2 r
            in
            assert
              (StringSet.mem (M.package_name dist2 (Package.index p))
                 clause.pos);
            (p, clause, explanation) :: s)
         !broken_new_packages [])
    end
  in

  if debug_time () then
    Format.eprintf "  Analysing problems: %f@." (Timer.stop t);

  (deps1, deps2, pred, st2,
   !results, !all_pkgs, all_conflicts, dep_src, graphs, broken_new_packages)

(****)

let get_clearly_broken_packages dist1_state dist dist2_state =
  let t = Timer.start () in
  let unsat_dep d =
    not (List.exists (fun cstr -> M.dep_can_be_satisfied dist cstr) d) in
  let was_installable p =
    match ListTbl.find dist1_state.dist.M.packages_by_name p.M.package with
      [] ->
        true
    | [q] ->
        let res = M.Solver.solve dist1_state.st q.M.num in
        M.Solver.reset dist1_state.st;
        res
    | _ ->
        assert false
  in
  let problems = ref [] in
  Hashtbl.iter
    (fun _ p ->
       let l =
         List.filter unsat_dep p.M.depends @
         List.filter unsat_dep p.M.pre_depends
       in
       if l <> [] && was_installable p then begin
         List.iter
           (fun d ->
              if debug_coinst () then
                Format.eprintf "Broken dependency: %a ==> %a@."
                  (Package.print dist) (Package.of_index p.M.num)
                  M.print_package_dependency [d];
             let r = [M.R_depends (p.M.num, d)] in
             let (clause, explanation) =
               problematic_packages dist1_state.dist dist dist2_state.dist r in
             problems :=
               (clause, StringSet.singleton p.M.package, explanation)
               :: !problems)
           l
       end)
    dist.M.packages_by_num;
  if debug_coinst () then
    Format.eprintf ">>> %a@."
      (Util.print_list (fun ch (cl, _, _) -> print_clause ch cl) ", ")
      !problems;
  if debug_time () then Format.eprintf "  Clearly broken: %f@." (Timer.stop t);
  !problems

let analyze_installability dist1_state dist dist2_state =
  let t = Timer.start () in
  let (deps, confl) = Coinst.compute_dependencies_and_conflicts dist in
  if debug_time () then
    Format.eprintf "      Deps and confls: %f@." (Timer.stop t);
  let (deps', confl') = Coinst.flatten_and_simplify dist deps confl in
  let t' = Timer.start () in
  let st = Coinst.generate_rules (Quotient.trivial dist) deps' confl' in
  if debug_time () then
    Format.eprintf "      Generate rules: %f@." (Timer.stop t');
  if debug_time () then Format.eprintf "    Preparing: %f@." (Timer.stop t);
  let package_name p =
    (Hashtbl.find dist.M.packages_by_num (Package.index p)).M.package in
  let is_installable p =
    let res = M.Solver.solve st (Package.index p) in
    M.Solver.reset st;
    res
  and was_installable p =
    let nm = package_name p in
    match ListTbl.find dist1_state.dist.M.packages_by_name nm with
      [] ->
        true
    | [q] ->
        let res = M.Solver.solve dist1_state.st q.M.num in
        M.Solver.reset dist1_state.st;
        res
    | _ ->
        assert false
  in
  let broken_pkgs = ref PSet.empty in

  let to_consider = ListTbl.create 101 in
  let add_package p f =
    let f = Formula.normalize f in
    ListTbl.add to_consider f p
  in
  PTbl.iteri
    (fun p f ->
       if
         not (Formula.implies Formula._true f) &&
         (Formula.implies f Formula._false ||
          Formula.fold (fun _ n -> n + 1) f 0 > 1)
       then
         add_package p f)
    deps';
  ListTbl.iter
    (fun f l ->
       let p = List.hd l in
       if not (is_installable p) then begin
         let l = List.filter was_installable l in
         broken_pkgs := List.fold_right PSet.add l !broken_pkgs
       end)
    to_consider;
  let pr_t = Timer.start () in
  let problems =
    if PSet.is_empty !broken_pkgs then
      []
    else begin
      let st_init =
        M.generate_rules_restricted dist (pset_indices !broken_pkgs) in
      PSet.fold
        (fun p l ->
           let i = Package.index p in
           let res = M.Solver.solve st_init i in
           assert (not res);
           let r = M.Solver.collect_reasons st_init i in
           M.Solver.reset st_init;
           let (clause, explanation) =
             problematic_packages dist1_state.dist dist dist2_state.dist r in
           (clause, StringSet.singleton (package_name p), explanation) :: l)
        !broken_pkgs []
    end
  in
  if debug_time () then begin
    Format.eprintf "    Computing problems: %f@." (Timer.stop pr_t);
    Format.eprintf "  Finding non-inst packages: %f@." (Timer.stop t)
  end;
  problems

(****)

let rec find_problematic_packages
          ?(check_new_packages = false) dist1_state dist2_state is_preserved =
  let t = Timer.start () in
  let dist2 = M.new_pool () in
  M.merge2 dist2 (fun p -> not (is_preserved p.M.package)) dist2_state.dist;
  M.merge2 dist2 (fun p -> is_preserved p.M.package) dist1_state.dist;
  if debug_time () then
    Format.eprintf "  Building target dist: %f@." (Timer.stop t);
  let problems = get_clearly_broken_packages dist1_state dist2 dist2_state in
  if
    List.exists (fun (cl, _, _) -> StringSet.cardinal cl.pos = 1) problems
  then
    problems
  else
  let (deps1, deps2, pred, st2,
       results, all_pkgs, all_conflicts,
       dep_src, graphs, broken_new_packages) =
    analyze ~check_new_packages ~reference:dist2_state dist1_state dist2
  in
let t = Timer.start () in
  let problems =
    List.fold_left
      (fun f { i_issue = s; i_clause = clause; i_explain = explanation } ->
        (clause,
         PSet.fold
           (fun p s ->
             StringSet.add (M.package_name dist2 (Package.index p)) s)
           s StringSet.empty,
         explanation) :: f)
      [] graphs
  in
  let problems =
    List.fold_left
      (fun f (p, ppkgs, explanation) ->
         (ppkgs,
          StringSet.singleton (M.package_name dist2 (Package.index p)),
          explanation) :: f)
      problems broken_new_packages
  in
  if debug_coinst () then
    Format.eprintf ">>> %a@."
      (Util.print_list (fun ch (cl, _, _) -> print_clause ch cl) ", ")
      problems;
  if debug_time () then
    Format.eprintf "  Compute problematic package names: %f@." (Timer.stop t);
  problems

let rec find_non_inst_packages dist1_state dist2_state is_preserved =
  let t = Timer.start () in
  let dist = M.new_pool () in
  M.merge2 dist (fun p -> not (is_preserved p.M.package)) dist2_state.dist;
  M.merge2 dist (fun p -> is_preserved p.M.package) dist1_state.dist;
  if debug_time () then
    Format.eprintf "  Building target dist: %f@." (Timer.stop t);
  let problems = get_clearly_broken_packages dist1_state dist dist2_state in
  if
    List.exists (fun (cl, _, _) -> StringSet.cardinal cl.pos = 1) problems
  then
    problems
  else begin
    let problems = analyze_installability dist1_state dist dist2_state in
    if debug_coinst () then
      Format.eprintf ">>> %a@."
        (Util.print_list (fun ch (cl, _, _) -> print_clause ch cl) ", ")
        problems;
    problems
  end

(****)

module Union_find = Util.Union_find

let find_clusters dist1_state dist2_state is_preserved groups merge =
  let dist2 = M.new_pool () in
  M.merge2 dist2 (fun p -> true) dist1_state.dist;
  let first_new = dist2.M.size in
  M.merge2 dist2 (fun p -> not (is_preserved p.M.package)) dist2_state.dist;

  let first_dummy = dist2.M.size in
ignore first_dummy;

  let group_reprs = Hashtbl.create 101 in
  let group_classes = Hashtbl.create 101 in
  let group_pkgs = Hashtbl.create 101 in
  List.iter
    (fun (l, elt) ->
       let q = List.hd l in
       let pkg v =
         let pseudo = "<" ^ q ^ "/" ^ v ^ ">" in
         Hashtbl.add group_reprs pseudo q;
         let provides = "<" ^ q ^ ">" in
         let v = (0, "none", None) in
         { M.num = 0; package = pseudo; version = v; source = (pseudo, v);
           section = ""; architecture = "";
           depends = []; recommends = []; suggests = []; enhances = [];
           pre_depends = []; provides = [[provides, None]];
           conflicts = [[provides, None]];
           breaks = []; replaces = [] }
       in
       let old_grp = Package.of_index (M.add_package dist2 (pkg "OLD")) in
       let new_grp = Package.of_index (M.add_package dist2 (pkg "NEW")) in
       Hashtbl.add group_pkgs q (old_grp, new_grp);
       Hashtbl.add group_classes q elt;
       List.iter (fun p -> Hashtbl.add group_reprs p q) l)
    groups;
  let group_repr p =
    let nm = M.package_name dist2 (Package.index p) in
    try Hashtbl.find group_reprs nm with Not_found -> ""
  in
  let same_group p q = group_repr p == group_repr q in
  let group_class p =
    try Some (Hashtbl.find group_classes p) with Not_found -> None
  in

  let old_version = PTbl.init dist2 (fun p -> p) in
  let new_version = PTbl.init dist2 (fun p -> p) in
  ListTbl.iter
    (fun nm l ->
       match l with
         [p] ->
           ()
       | [p; q] ->
           let i = min p.M.num q.M.num in
           let j = max p.M.num q.M.num in
           PTbl.set old_version (Package.of_index j) (Package.of_index i);
           PTbl.set new_version (Package.of_index i) (Package.of_index j)
       | _ ->
           assert false)
    dist2.M.packages_by_name;
  let is_old p = Package.index p < first_new in
  let is_new p =
    Package.index p >= first_new && Package.index p < first_dummy in
  let is_dummy p = Package.index p >= first_dummy in

  let (deps2full, confl2full) =
    Coinst.compute_dependencies_and_conflicts dist2 in

  let confl2 = Conflict.create dist2 in
  Conflict.iter confl2full
    (fun p q ->
      let p' = PTbl.get old_version p in
      let q' = PTbl.get old_version q in
      (* We omit conflicts between old and new version of packages
         in a same group. *)
      if
        (is_old p && is_old q) || (is_new p && is_new q) ||
        is_dummy p || not (same_group p q)
      then
        Conflict.add confl2 p' q');

  let marked_conj o old_f n new_f =
    let common_part f f' =
      Formula.filter
        (fun d -> Formula.exists (fun d' -> Disj.implies d' d) f) f'
    in
    let common_f =
      Formula.conj (common_part old_f new_f) (common_part new_f old_f) in
    Formula.conj
      (Formula.conj common_f (Formula.disj (Formula.lit n) old_f))
      (Formula.disj (Formula.lit o) new_f)
  in

  let quotient_formula p f =
    Formula.fold
      (fun d f ->
         let disj = Disj.to_lits d in
         let variable_part = PSet.filter (fun p -> group_repr p <> "") disj in
         if PSet.is_empty variable_part then
           Formula.conj (Formula.of_disj d) f
         else begin
           let stable_part = PSet.filter (fun p -> group_repr p = "") disj in
           let s =
             PSet.fold (fun p s -> StringSet.add (group_repr p) s)
               variable_part StringSet.empty
           in
(*
Format.eprintf "Involved (%s / %a):" (group_repr p) (Package.print dist2) p;
StringSet.iter (fun nm -> Format.eprintf " %s" nm) s;
Format.eprintf "@.";
*)
           let f' =
             StringSet.fold
               (fun nm f ->
                  let s1 =
                    PSet.filter
                      (fun p -> is_new p && group_repr p = nm) variable_part
                  in
                  let s2 =
                    PSet.filter
                      (fun p -> is_old p && group_repr p = nm) variable_part
                  in
                  let d1 =
                    PSet.fold
                      (fun p d ->
                         Disj.disj (Disj.lit (PTbl.get old_version p)) d)
                      s1 Disj._false
                  in
                  let d2 = Disj.of_lits s2 in
(*
Format.eprintf "?? %b %b %a %a@." (nm = group_repr p) (is_old p) (Disj.print dist2) d1 (Disj.print dist2) d2;
*)
                  Formula.disj
                    (if Disj.equiv d1 d2 then
                       Formula.of_disj d1
                     else if nm <> group_repr p then
(*
                       Formula.conj
                         (Formula.of_disj d1)
                         (Formula.of_disj d2)
*)
                       let (o, n) = Hashtbl.find group_pkgs nm in
                       marked_conj
                         o (Formula.of_disj d2) n (Formula.of_disj d1)
(*
                       Formula.conj
                         (Formula.of_disj (Disj.disj d1 (Disj.lit o)))
                         (Formula.of_disj (Disj.disj d2 (Disj.lit n)))
*)
                     else if is_old p then
                       Formula.of_disj d2
                     else
                       Formula.of_disj d1)
                    f)
               s Formula._false
           in
           let f' =
             Formula.disj f' (Formula.of_disj (Disj.of_lits stable_part)) in
(*
Format.eprintf "%a ==> %a@." (Disj.print dist2) d (Formula.print dist2) f';
*)
           Formula.conj f f'
         end)
      f Formula._true
  in
  let deps2 = PTbl.mapi quotient_formula deps2full in
  PTbl.iteri
    (fun p f ->
       let q = PTbl.get old_version p in
       if p <> q then begin
         let nm = group_repr p in
         let (o, n) = Hashtbl.find group_pkgs nm in
         PTbl.set deps2 q
           (marked_conj o (PTbl.get deps2 q) n (PTbl.get deps2 p));
(*
(Formula.conj (Formula.disj (Formula.lit n) (PTbl.get deps2 q)) (Formula.disj (Formula.lit o) (PTbl.get deps2 p)));
*)
(*
         PTbl.set deps2 q (Formula.conj (PTbl.get deps2 q) (PTbl.get deps2 p));
*)
         PTbl.set deps2 p Formula._true
       end else if is_new q then begin
         let nm = group_repr p in
         let (o, n) = Hashtbl.find group_pkgs nm in
         PTbl.set deps2 q (Formula.disj (Formula.lit o) (PTbl.get deps2 q))
       end)
    deps2;

  let (deps2', confl2') = Coinst.flatten_and_simplify dist2 deps2 confl2 in

  let pred = compute_predecessors dist1_state.dist dist2 in

  let confl1 = dist1_state.confl in

  let new_conflicts = ref [] in
  Conflict.iter confl2
    (fun p2 q2 ->
       let i = PTbl.get pred p2 in
       let j = PTbl.get pred q2 in
       if i <> -1 && j <> -1 then begin
         let p1 = Package.of_index i in
         let q1 = Package.of_index j in
         if not (Conflict.check confl1 p1 q1) then begin
           if debug_coinst () then begin
             Format.eprintf "possible new conflict: %a %a@."
               (Package.print_name dist1_state.dist) p1
               (Package.print_name dist1_state.dist) q1;
           end;
           new_conflicts := (p2, q2) :: !new_conflicts;
         end
       end);

  (* Only consider new dependencies. *)
  let deps2 = new_deps pred dist1_state.deps dist2 deps2 in

  (* Compute the corresponding flattened dependencies. *)
  let deps2 =
    PTbl.mapi
       (fun p f ->
          Formula.fold
            (fun d f ->
               Formula.conj
                 (PSet.fold
                    (fun p f -> Formula.disj (PTbl.get deps2' p) f)
                    (Disj.to_lits d) Formula._false) f)
            f Formula._true)
      deps2
  in

  (* Only keep those that are new... *)
  let deps2 = new_deps pred dist1_state.deps' dist2 deps2 in

  (* ...and that are indeed in the flattened repository *)
  let deps2 =
    PTbl.mapi
      (fun p f ->
         let f' = PTbl.get deps2' p in
         Formula.filter
           (fun d ->
              Formula.exists (fun d' -> Disj.equiv d d') f') f)
      deps2
  in

  (* Only keep relevant conflicts. *)
  let dep_targets = ref PSet.empty in
  PTbl.iteri
    (fun _ f ->
       Formula.iter f
         (fun d ->
            Disj.iter d (fun p -> dep_targets := PSet.add p !dep_targets)))
    deps2;
  Conflict.iter confl2'
    (fun p2 q2 ->
       let i1 = PTbl.get pred p2 in
       let j1 = PTbl.get pred q2 in
       if
         not (is_dummy p2 ||
              (PSet.mem p2 !dep_targets && j1 <> -1) ||
              (PSet.mem q2 !dep_targets && i1 <> -1) ||
              (PSet.mem p2 !dep_targets && PSet.mem q2 !dep_targets))
       then
         Conflict.remove confl2' p2 q2);
  List.iter (fun (p2, q2) -> Conflict.remove confl2' p2 q2) !new_conflicts;
  (* As a consequence, some new dependencies might not be relevant anymore. *)
  let deps2 = Coinst.remove_irrelevant_deps confl2' deps2 in

  (* Add self dependencies for packages with conflicts, as we want to
     consider them as well to find possible problems. *)
  let deps2 =
    PTbl.mapi
      (fun p f ->
         if Conflict.has confl2' p && PTbl.get pred p <> -1 then
           Formula.conj (Formula.lit p) f
         else
           f)
      deps2
  in

  let merge v v' =
    match v, v' with
      Some c, Some c' -> merge c c'; v
    | Some _, None    -> v
    | None, Some _    -> v'
    | None, None      -> None
  in

  let group_confl = Hashtbl.create 101 in
  PTbl.iteri
    (fun p f ->
       Formula.iter f
         (fun d ->
if debug_cluster () then begin
Format.eprintf "New dep %a ==> %a@."
(Package.print_name dist2) p
(Disj.print dist2) d
end;
            let c =
              if Disj.implies1 p d then begin
if debug_cluster () then begin
let s = group_repr p in
if s <> "" then Format.eprintf "   ==> %s@." s
end;
                group_class (group_repr p)
              end else
                Disj.fold
                  (fun p c ->
                     if is_dummy p then begin
if debug_cluster () then begin
let s = group_repr p in
if s <> "" then Format.eprintf "   ==> %s@." s
end;
                       merge c (group_class (group_repr p))
                     end else
                       c)
                  d None
            in
            let c = Union_find.elt c in
            Disj.iter d
              (fun p ->
                 if not (is_dummy p) then
                   let c' =
                     try
                       Hashtbl.find group_confl p
                     with Not_found ->
                       Union_find.elt None
                   in
                   Union_find.merge c c' merge;
                   Hashtbl.replace group_confl p c)))
    deps2;

  Conflict.iter confl2'
    (fun p p' ->
       if not (is_dummy p) then begin
(*
Format.eprintf "Old conflict %a ## %a@."
(Package.print dist2) p (Package.print dist2) p';
*)
         try
           let c = Hashtbl.find group_confl p in
           let c' = Hashtbl.find group_confl p' in
           Union_find.merge c c' merge
         with Not_found ->
           assert false
       end);

  List.iter
    (fun (p, p') ->
      let c = group_class (group_repr p) in
      let c' = group_class (group_repr p') in
if debug_cluster () then
Format.eprintf "New conflict %s ## %s@." (group_repr p) (group_repr p');
      ignore (merge c c'))
    !new_conflicts;

  PTbl.iteri
    (fun p f ->
       if is_new p && PTbl.get old_version p = p then begin
if debug_cluster () then
Format.eprintf "New package %a ==> %a@."
  (Package.print_name dist2) p
  (Formula.print dist2) f;
         Formula.iter f
           (fun d ->
              ignore
                (Disj.fold
                   (fun p c ->
                      if is_dummy p then
                        merge c (group_class (group_repr p))
                      else
                        c)
                   d None))
       end)
    deps2'
