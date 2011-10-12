let debug = false

module StringSet = Set.Make (String)

module M = Deb_lib
module Coinst = Coinst_common.F(M)
module Repository = Coinst.Repository
open Repository
module Quotient = Coinst.Quotient
module Graph = Graph.F (Repository)

module IntSet =
  Set.Make (struct type t = int let compare (x : int) y = compare x y end)

module PSetSet = Set.Make (PSet)
module PSetMap = Map.Make (PSet)

module Timer = Util.Timer

let get_list' h n =
  try
    Hashtbl.find h n
  with Not_found ->
    let r = ref [] in
    Hashtbl.add h n r;
    r

let add_to_list h n p =
  let l = get_list' h n in
  l := p :: !l

let get_list h n = try !(Hashtbl.find h n) with Not_found -> []

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

type st =
  { dist : M.pool; deps : Formula.t PTbl.t; confl : Conflict.t;
    pieces : (int, Package.t * Disj.t) Hashtbl.t;
    pieces_in_confl : (Package.t, int list ref) Hashtbl.t;
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
if debug then Format.printf "Try to add %a => %a@." (Package.print_name st.dist) p
         (Disj.print st.dist) d;
  (* XXX
     When adding a package in st.set, one could also check that d is not
     implied by any of the dependencies of a package already in st.set *)
  if
    not (IntSet.exists
           (fun i' ->
              let (_, d') = Hashtbl.find st.pieces i' in
              Disj.implies d d' || Disj.implies d' d)
           st.installed)
      &&
    (PSet.mem p st.set || st.check (PSet.add p st.set))
  then begin
    let st =
      {st with set = PSet.add p st.set;
       installed = IntSet.add i st.installed}
    in
    if debug then print_prob st;
    (* Make sure that there is at least one piece in conflict for all
       dependencies, then consider all possible additions *)
    Disj.fold
      (fun p cont st ->
         if
           PSet.exists
             (fun q ->
                List.exists (fun i -> IntSet.mem i st.installed)
                  (get_list st.pieces_in_confl q))
             (Conflict.of_package st.confl p)
         then
           cont st
         else
           ignore
             (PSet.fold
                (fun q st -> 
                   List.fold_right (fun j st -> do_add_piece st j cont)
                     (get_list st.pieces_in_confl q) st)
                (Conflict.of_package st.confl p) st))
      d
      (fun st ->
if debug then Format.printf "Considering all possible additions in %d: %a...@."
i (Disj.print st.dist) d;
        Disj.fold
         (fun p cont ->
            PSet.fold
              (fun q cont ->
                 List.fold_right (fun j cont st -> maybe_add_piece st j cont)
                   (get_list st.pieces_in_confl q) cont)
              (Conflict.of_package st.confl p) cont)
           d cont st)
      st
  end

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
  let pieces_in_confl = Hashtbl.create 101 in
  PTbl.iteri
    (fun p f ->
      Formula.iter f
        (fun d ->
          incr last_piece;
          let i = !last_piece in
          Hashtbl.add pieces i (p, d);
          Disj.iter d (fun p -> add_to_list pieces_in_confl p i)))
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

let problematic_packages dist1 deps1 confl1 dist2 pred reasons =
  List.fold_left
    (fun s r ->
       match r with
         M.R_depends (n, l) ->
           let p = Package.of_index n in
           let resolve_dep dist l =
             Disj.lit_disj
               (List.map Package.of_index
                  (List.flatten (List.map (M.resolve_package_dep dist) l)))
           in
           let d1 = resolve_dep dist1 l in
           let d2 = resolve_dep dist2 l in
           let s2 =
             Disj.fold
               (fun p s ->
                  let i = PTbl.get pred p in
                  if i = -1 then s else PSet.add (Package.of_index i) s)
               d2 PSet.empty
           in
           let delta = PSet.diff (Disj.to_lits d1) s2 in
           let is_new d =
             let i1 = PTbl.get pred p in
             i1 <> -1 &&
             not (Formula.implies1
                    (PTbl.get deps1 (Package.of_index i1)) d)
           in
           if is_new (Disj.lit_disj (PSet.elements s2)) then begin
             let s =
               if is_new d1 then
                 Formula.disj s
                   (Formula.lit (Package.of_index (PTbl.get pred p)))
               else
                 s
             in
             Formula.disj s
               (Formula.of_disj (Disj.lit_disj (PSet.elements delta)))
           end else
             s
       | M.R_conflict (i2, j2, Some (k2, l)) ->
           let p2 = Package.of_index i2 in
           let q2 = Package.of_index j2 in
           let i1 = PTbl.get pred p2 in
           let j1 = PTbl.get pred q2 in
           if
             i1 <> -1 && j1 <> -1 &&
             not (Conflict.check confl1
                    (Package.of_index i1) (Package.of_index j1))
           then begin
             (* If the conflict did already exist, we should not upgrade k;
                otherwise, we should not upgrade l *)
             let confls =
               List.flatten (List.map (M.resolve_package_dep dist1) l) in
             let p = (min i1 j1, max i1 j1) in
             let k1 = PTbl.get pred (Package.of_index k2) in
             if
               List.exists (fun k1' -> p = (min k1 k1', max k1 k1')) confls
             then begin
               Formula.disj s (Formula.lit (Package.of_index k1))
             end else begin
               let k1' = if i1 = k1 then j1 else i1 in
               Formula.disj s (Formula.lit (Package.of_index k1'))
             end
           end else
             s
       | M.R_conflict (_, _, None) ->
           s)
    Formula._false reasons

(****)

type state =
  { dist : M.deb_pool;
    deps : Formula.t PTbl.t;
    confl : Conflict.t;
    deps' : Formula.t PTbl.t;
    confl' : Conflict.t;
    st : M.Solver.state }

let prepare_analyze dist =
  let (deps, confl) = Coinst.compute_dependencies_and_conflicts dist in
  let (deps', confl') = Coinst.flatten_and_simplify dist deps confl in
  let st = Coinst.generate_rules (Quotient.trivial dist) deps' confl' in
  { dist; deps; confl; deps'; confl'; st }

let analyze ?(check_new_packages = false) dist1_state dist2 =
  let
    { dist = dist1; deps = deps1; confl = confl1;
      deps' = deps1'; confl' = confl1'; st = st1 }
  = dist1_state
  in
let t = Timer.start () in
let t' = Timer.start () in
  let (deps2, confl2) = Coinst.compute_dependencies_and_conflicts dist2 in
Format.eprintf "    Deps and confls: %f@." (Timer.stop t');
  let (deps2', confl2') = Coinst.flatten_and_simplify dist2 deps2 confl2 in
let t' = Timer.start () in
  let st2 = Coinst.generate_rules (Quotient.trivial dist2) deps2' confl2' in
Format.eprintf "    Rules: %f@." (Timer.stop t');
Format.eprintf "  Target dist: %f@." (Timer.stop t);

let t = Timer.start () in
  let pred =
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
  in

  let new_conflicts = ref [] in
  Conflict.iter confl2
    (fun p2 q2 ->
       let i = PTbl.get pred p2 in
       let j = PTbl.get pred q2 in
       if i <> -1 && j <> -1 then begin
         let p1 = Package.of_index i in
         let q1 = Package.of_index j in
         if not (Conflict.check confl1 p1 q1) then begin
  if true (*debug*) then begin
           Format.printf "possible new conflict: %a %a@."
             (Package.print_name dist1) p1
             (Package.print_name dist1) q1;
  end;
           new_conflicts := (p2, q2) :: !new_conflicts;
  (*XXXXX????
           Conflict.remove confl2 p2 q2
  *)
         end
       end);

  let results = ref PSetSet.empty in
  let add_result s =
    if not (PSetSet.mem s !results) then begin
  Format.printf "==>";
  PSet.iter (fun p -> Format.printf " %a" (Package.print_name dist2) p) s;
  Format.printf "@.";
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
  (* As a consequence, some new dependencies might not be relevant anymore. *)
  let deps2 = Coinst.remove_irrelevant_deps confl2' deps2 in

  (*
  Graph.output "/tmp/update.dot"
    ~package_weight:(fun p ->
      if Formula.implies (Formula.lit p) (PTbl.get deps2 p) then
        (if PTbl.get pred p = -1 then 1. else 10.)
      else 1000.)
    (Quotient.trivial dist2) deps2 confl2';
  *)

  (* Flattening may have added self dependencies for new packages,
     which are not relevant. *)
  let deps2 =
    PTbl.mapi
      (fun p f -> if PTbl.get pred p = -1 then Formula._true else f)
      deps2
  in
Format.eprintf "  Init: %f@." (Timer.stop t);

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
  if true (*debug*) then begin
  Format.printf "Not minimal:";
  List.iter (fun p -> Format.printf " %a" (Package.print_name dist2) p) l;
  Format.printf "@.";
  end;
      end else begin
        add_result s
      end;
      false
    end
  in
let t = Timer.start () in
  find_problems dist2 deps2 confl2' check;
Format.eprintf "  Enumerating problems: %f@." (Timer.stop t);
  (****)

let t = Timer.start () in
  let all_pkgs = ref PSet.empty in
  let all_conflicts = Conflict.create dist2 in
  let dep_src = PTbl.create dist2 PSet.empty in
  let dep_trg = PTbl.create dist2 PSet.empty in
  let add_rel r p q = PTbl.set r p (PSet.add q (PTbl.get r p)) in

  let graphs =
    if PSetSet.is_empty !results then [] else begin
      let s = PSetSet.fold PSet.union !results PSet.empty in
let t = Timer.start () in
      let st2init = M.generate_rules_restricted dist2 (pset_indices s) in
Format.eprintf "    Generating constraints: %f@." (Timer.stop t);
      List.map
        (fun s ->
           let l = List.map Package.index (PSet.elements s) in
           let nm =
             String.concat ","
               (List.map (fun p -> M.package_name dist2 (Package.index p))
                  (PSet.elements s))
           in
           let res = M.Solver.solve_lst st2init l in
           assert (not res);
           let r = M.Solver.collect_reasons_lst st2init l in
           M.Solver.reset st2init;
           let confl = Conflict.create dist2 in
           let deps = PTbl.create dist2 Formula._true in
           let pkgs = ref PSet.empty in
           let package i =
             let p = Package.of_index i in pkgs := PSet.add p !pkgs; p in
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
           let ppkgs = problematic_packages dist1 deps1 confl1 dist2 pred r in
           (s, nm, !pkgs, deps, confl, ppkgs))
        (PSetSet.elements !results)
    end
  in

  let broken_new_packages = ref PSet.empty in
  if check_new_packages then begin
    PTbl.iteri
      (fun p _ ->
         if PTbl.get pred p = -1 then begin
(*Format.eprintf "??? %a@." (Package.print dist2) p;*)
           if not (M.Solver.solve st2 (Package.index p)) then
             broken_new_packages := PSet.add p !broken_new_packages;
           M.Solver.reset st2
         end)
      deps2
  end;
Format.eprintf "  Analysing problems: %f@." (Timer.stop t);

  (deps1, deps2, pred, st2,
   !results, !all_pkgs, all_conflicts, dep_src, graphs, !broken_new_packages)

(****)

let rec find_problematic_packages
          ?(check_new_packages = false) dist1_state dist2' is_preserved =
  let {dist = dist1} = dist1_state in
let t = Timer.start () in
  let dist2 = M.new_pool () in
  M.merge2 dist2 (fun p -> not (is_preserved p.M.package)) dist2';
  M.merge2 dist2 (fun p -> is_preserved p.M.package) dist1;
Format.eprintf "  Building target dist: %f@." (Timer.stop t);

  let (deps1, deps2, pred, st2,
       results, all_pkgs, all_conflicts,
       dep_src, graphs, broken_new_packages) =
    analyze ~check_new_packages dist1_state dist2
  in
let t = Timer.start () in
  let problems =
    List.fold_left (fun f (s, _, _, _, _, ppkgs) -> Formula.conj f ppkgs)
      Formula._true graphs
  in
  Format.printf ">>> %a@." (Formula.print ~compact:true dist1) problems;
  Format.printf ">>>";
  PSet.iter (fun p -> Format.printf " %a" (Package.print dist2) p)
    broken_new_packages;
  Format.printf "@.";

let res =
  Formula.fold
    (fun d s ->
       StringSet.add
         (M.package_name dist1 (Package.index (PSet.choose (Disj.to_lits d))))
         s)
    problems
    (PSet.fold
       (fun p s -> StringSet.add (M.package_name dist2 (Package.index p)) s)
       broken_new_packages StringSet.empty)
in
Format.eprintf "  Compute problematic package names: %f@." (Timer.stop t);
res
