(*  Title:      HOL/Tools/Sledgehammer/sledgehammer_isar_proof.ML
    Author:     Jasmin Blanchette, TU Muenchen
    Author:     Steffen Juilf Smolka, TU Muenchen

Basic data structures for representing and basic methods
for dealing with Isar proof texts.
*)

signature SLEDGEHAMMER_ISAR_PROOF =
sig
  type proof_method = Sledgehammer_Proof_Methods.proof_method

  type label = string * int
  type facts = label list * string list (* local and global facts *)

  datatype isar_qualifier = Show | Then

  datatype isar_proof =
    Proof of (string * typ) list * (label * term) list * isar_step list
  and isar_step =
    Let of term * term |
    Prove of isar_qualifier list * (string * typ) list * label * term * isar_proof list
      * facts * proof_method list * string

  val no_label : label

  val label_ord : label * label -> order
  val string_of_label : label -> string
  val sort_facts : facts -> facts

  val steps_of_isar_proof : isar_proof -> isar_step list
  val label_of_isar_step : isar_step -> label option
  val facts_of_isar_step : isar_step -> facts
  val proof_methods_of_isar_step : isar_step -> proof_method list

  val fold_isar_steps : (isar_step -> 'a -> 'a) -> isar_step list -> 'a -> 'a
  val map_isar_steps : (isar_step -> isar_step) -> isar_proof -> isar_proof
  val add_isar_steps : isar_step list -> int -> int

  structure Canonical_Label_Tab : TABLE

  val canonical_label_ord : (label * label) -> order

  val comment_isar_proof : (label -> proof_method list -> string) -> isar_proof -> isar_proof
  val chain_isar_proof : isar_proof -> isar_proof
  val kill_useless_labels_in_isar_proof : isar_proof -> isar_proof
  val relabel_isar_proof_canonically : isar_proof -> isar_proof
  val relabel_isar_proof_nicely : isar_proof -> isar_proof
  val rationalize_obtains_in_isar_proofs : Proof.context -> isar_proof -> isar_proof

  val string_of_isar_proof : Proof.context -> int -> int -> isar_proof -> string
end;

structure Sledgehammer_Isar_Proof : SLEDGEHAMMER_ISAR_PROOF =
struct

open ATP_Util
open ATP_Proof
open ATP_Problem_Generate
open ATP_Proof_Reconstruct
open Sledgehammer_Util
open Sledgehammer_Proof_Methods
open Sledgehammer_Isar_Annotate

type label = string * int
type facts = label list * string list (* local and global facts *)

datatype isar_qualifier = Show | Then

datatype isar_proof =
  Proof of (string * typ) list * (label * term) list * isar_step list
and isar_step =
  Let of term * term |
  Prove of isar_qualifier list * (string * typ) list * label * term * isar_proof list
    * facts * proof_method list * string

val no_label = ("", ~1)

(* cf. "label_ord" below *)
val assume_prefix = "a"
val have_prefix = "f"

fun label_ord ((s1, i1), (s2, i2)) =
  (case int_ord (apply2 String.size (s1, s2)) of
    EQUAL =>
    (case string_ord (s1, s2) of
      EQUAL => int_ord (i1, i2)
    | ord => ord (* "assume" before "have" *))
  | ord => ord)

fun string_of_label (s, num) = s ^ string_of_int num

(* Put the nearest local label first, since it's the most likely to be replaced by a "hence".
   (Some preplaying proof methods, e.g. "blast", react poorly to fact reorderings.) *)
fun sort_facts (lfs, gfs) = (sort (label_ord o swap) lfs, sort string_ord gfs)

fun steps_of_isar_proof (Proof (_, _, steps)) = steps

fun label_of_isar_step (Prove (_, _, l, _, _, _, _, _)) = SOME l
  | label_of_isar_step _ = NONE

fun subproofs_of_isar_step (Prove (_, _, _, _, subs, _, _, _)) = subs
  | subproofs_of_isar_step _ = []

fun facts_of_isar_step (Prove (_, _, _, _, _, facts, _, _)) = facts
  | facts_of_isar_step _ = ([], [])

fun proof_methods_of_isar_step (Prove (_, _, _, _, _, _, meths, _)) = meths
  | proof_methods_of_isar_step _ = []

fun fold_isar_step f step =
  fold (steps_of_isar_proof #> fold_isar_steps f) (subproofs_of_isar_step step) #> f step
and fold_isar_steps f = fold (fold_isar_step f)

fun map_isar_steps f =
  let
    fun map_proof (Proof (fix, assms, steps)) = Proof (fix, assms, map map_step steps)
    and map_step (step as Let _) = f step
      | map_step (Prove (qs, xs, l, t, subs, facts, meths, comment)) =
        f (Prove (qs, xs, l, t, map map_proof subs, facts, meths, comment))
  in map_proof end

val add_isar_steps = fold_isar_steps (fn Prove _ => Integer.add 1 | _ => I)

(* canonical proof labels: 1, 2, 3, ... in post traversal order *)
fun canonical_label_ord (((_, i1), (_, i2)) : label * label) = int_ord (i1, i2)

structure Canonical_Label_Tab = Table(
  type key = label
  val ord = canonical_label_ord)

fun comment_isar_step comment_of (Prove (qs, xs, l, t, subs, facts, meths, _)) =
    Prove (qs, xs, l, t, subs, facts, meths, comment_of l meths)
  | comment_isar_step _ step = step
fun comment_isar_proof comment_of = map_isar_steps (comment_isar_step comment_of)

fun chain_qs_lfs NONE lfs = ([], lfs)
  | chain_qs_lfs (SOME l0) lfs =
    if member (op =) lfs l0 then ([Then], remove (op =) l0 lfs) else ([], lfs)

fun chain_isar_step lbl (Prove (qs, xs, l, t, subs, (lfs, gfs), meths, comment)) =
    let val (qs', lfs) = chain_qs_lfs lbl lfs in
      Prove (qs' @ qs, xs, l, t, map chain_isar_proof subs, (lfs, gfs), meths, comment)
    end
  | chain_isar_step _ step = step
and chain_isar_steps _ [] = []
  | chain_isar_steps prev (i :: is) =
    chain_isar_step prev i :: chain_isar_steps (label_of_isar_step i) is
and chain_isar_proof (Proof (fix, assms, steps)) =
  Proof (fix, assms, chain_isar_steps (try (List.last #> fst) assms) steps)

fun kill_useless_labels_in_isar_proof proof =
  let
    val used_ls =
      fold_isar_steps (facts_of_isar_step #> fst #> union (op =)) (steps_of_isar_proof proof) []

    fun kill_label l = if member (op =) used_ls l then l else no_label

    fun kill_step (Prove (qs, xs, l, t, subs, facts, meths, comment)) =
        Prove (qs, xs, kill_label l, t, map kill_proof subs, facts, meths, comment)
      | kill_step step = step
    and kill_proof (Proof (fix, assms, steps)) =
      Proof (fix, map (apfst kill_label) assms, map kill_step steps)
  in
    kill_proof proof
  end

fun relabel_isar_proof_canonically proof =
  let
    fun next_label l (next, subst) =
      let val l' = ("", next) in (l', (next + 1, (l, l') :: subst)) end

    fun relabel_step (Prove (qs, fix, l, t, subs, (lfs, gfs), meths, comment))
          (accum as (_, subst)) =
        let
          val lfs' = maps (the_list o AList.lookup (op =) subst) lfs
          val ((subs', l'), accum') = accum
            |> fold_map relabel_proof subs
            ||>> next_label l
        in
          (Prove (qs, fix, l', t, subs', (lfs', gfs), meths, comment), accum')
        end
      | relabel_step step accum = (step, accum)
    and relabel_proof (Proof (fix, assms, steps)) =
      fold_map (fn (l, t) => next_label l #> apfst (rpair t)) assms
      ##>> fold_map relabel_step steps
      #>> (fn (assms, steps) => Proof (fix, assms, steps))
  in
    fst (relabel_proof proof (0, []))
  end

val relabel_isar_proof_nicely =
  let
    fun next_label depth prefix l (accum as (next, subst)) =
      if l = no_label then
        (l, accum)
      else
        let val l' = (replicate_string (depth + 1) prefix, next) in
          (l', (next + 1, (l, l') :: subst))
        end

    fun relabel_step depth (Prove (qs, xs, l, t, subs, (lfs, gfs), meths, comment))
          (accum as (_, subst)) =
        let
          val lfs' = maps (the_list o AList.lookup (op =) subst) lfs
          val (l', accum' as (_, subst')) = next_label depth have_prefix l accum
          val subs' = map (relabel_proof subst' (depth + 1)) subs
        in
          (Prove (qs, xs, l', t, subs', (lfs', gfs), meths, comment), accum')
        end
      | relabel_step _ step accum = (step, accum)
    and relabel_proof subst depth (Proof (fix, assms, steps)) =
      (1, subst)
      |> fold_map (fn (l, t) => next_label depth assume_prefix l #> apfst (rpair t)) assms
      ||>> fold_map (relabel_step depth) steps
      |> (fn ((assms, steps), _) => Proof (fix, assms, steps))
  in
    relabel_proof [] 0
  end

fun stutter_single_letter s = String.extract (s, 0, SOME 1) ^ s

fun rationalize_obtains_in_isar_proofs ctxt =
  let
    fun rename_obtains xs (subst, ctxt) =
      let
        val Ts = map snd xs
        val new_names0 = map (stutter_single_letter o var_name_of_typ o body_type) Ts
        val (new_names, ctxt') = Variable.variant_fixes new_names0 ctxt
        val ys = map2 pair new_names Ts
      in
        (ys, ((map Free xs ~~ map Free ys) @ subst, ctxt'))
      end

    fun rationalize_step (Prove (qs, xs, l, t, subs, facts, meths, comment)) subst_ctxt =
        let
          val (xs', subst_ctxt' as (subst', _)) = rename_obtains xs subst_ctxt
          val t' = subst_atomic subst' t
          val subs' = map (rationalize_proof false subst_ctxt') subs
        in
          (Prove (qs, xs', l, t', subs', facts, meths, comment), subst_ctxt')
        end
    and rationalize_proof outer (subst_ctxt as (subst, ctxt)) (Proof (fix, assms, steps)) =
      let
        val (fix', subst_ctxt' as (subst', _)) =
          if outer then
            (* last call: eliminate any remaining skolem names (from SMT proofs) *)
            (fix, (subst @ map (fn x => (Free (apfst Name.skolem x), Free x)) fix, ctxt))
          else
            rename_obtains fix subst_ctxt
      in
        Proof (fix', map (apsnd (subst_atomic subst')) assms,
          fst (fold_map rationalize_step steps subst_ctxt'))
      end
  in
    rationalize_proof true ([], ctxt)
  end

val thesis_var = ((Auto_Bind.thesisN, 0), HOLogic.boolT)

fun is_thesis ctxt t =
  (case Vartab.lookup (Variable.binds_of ctxt) (fst thesis_var) of
    SOME (_, t') => HOLogic.mk_Trueprop t' aconv t
  | NONE => false)

val indent_size = 2

fun string_of_isar_proof ctxt0 i n proof =
  let
    val keywords = Thy_Header.get_keywords' ctxt0

    (* Make sure only type constraints inserted by the type annotation code are printed. *)
    val ctxt = ctxt0
      |> Config.put show_markup false
      |> Config.put Printer.show_type_emphasis false
      |> Config.put show_types false
      |> Config.put show_sorts false
      |> Config.put show_consts false

    fun add_str s' = apfst (suffix s')

    fun of_indent ind = replicate_string (ind * indent_size) " "
    fun of_moreover ind = of_indent ind ^ "moreover\n"
    fun of_label l = if l = no_label then "" else string_of_label l ^ ": "

    fun of_obtain qs nr =
      (if nr > 1 orelse (nr = 1 andalso member (op =) qs Then) then "ultimately "
       else if nr = 1 orelse member (op =) qs Then then "then "
       else "") ^ "obtain"

    fun of_show_have qs = if member (op =) qs Show then "show" else "have"
    fun of_thus_hence qs = if member (op =) qs Show then "then show" else "then have"

    fun of_have qs nr =
      if nr > 1 orelse (nr = 1 andalso member (op =) qs Then) then "ultimately " ^ of_show_have qs
      else if nr = 1 orelse member (op =) qs Then then of_thus_hence qs
      else of_show_have qs

    fun add_term term (s, ctxt) =
      (s ^ (term
            |> singleton (Syntax.uncheck_terms ctxt)
            |> annotate_types_in_term ctxt
            |> Print_Mode.setmp [] (Syntax.unparse_term ctxt #> Pretty.string_of)
            |> simplify_spaces
            |> maybe_quote keywords),
       ctxt |> perhaps (try (Variable.auto_fixes term)))

    fun using_facts [] [] = ""
      | using_facts ls ss = enclose "using " " " (space_implode " " (map string_of_label ls @ ss))

    (* Local facts are always passed via "using", which affects "meson" and "metis". This is
       arguably stylistically superior, because it emphasises the structure of the proof. It is also
       more robust w.r.t. preplay: Preplay is performed before chaining of local facts with "then"
       is introduced. See also "tac_of_method" in "Sledgehammer_Isar_Preplay". *)
    fun of_method ls ss meth =
      let val direct = is_proof_method_direct meth in
        using_facts ls (if direct then [] else ss) ^
        "by " ^ string_of_proof_method ctxt (if direct then ss else []) meth
      end

    fun of_free (s, T) =
      maybe_quote keywords s ^ " :: " ^
      maybe_quote keywords (simplify_spaces (Print_Mode.setmp [] (Syntax.string_of_typ ctxt) T))

    fun add_frees xs (s, ctxt) =
      (s ^ space_implode " and " (map of_free xs), ctxt |> fold Variable.auto_fixes (map Free xs))

    fun add_fix _ [] = I
      | add_fix ind xs = add_str (of_indent ind ^ "fix ") #> add_frees xs #> add_str "\n"

    fun add_assm ind (l, t) =
      add_str (of_indent ind ^ "assume " ^ of_label l) #> add_term t #> add_str "\n"

    fun of_subproof ind ctxt proof =
      let
        val ind = ind + 1
        val s = of_proof ind ctxt proof
        val prefix = "{ "
        val suffix = " }"
      in
        replicate_string (ind * indent_size - size prefix) " " ^ prefix ^
        String.extract (s, ind * indent_size, SOME (size s - ind * indent_size - 1)) ^
        suffix ^ "\n"
      end
    and of_subproofs _ _ _ [] = ""
      | of_subproofs ind ctxt qs subs =
        (if member (op =) qs Then then of_moreover ind else "") ^
        space_implode (of_moreover ind) (map (of_subproof ind ctxt) subs)
    and add_step_pre ind qs subs (s, ctxt) =
      (s ^ of_subproofs ind ctxt qs subs ^ of_indent ind, ctxt)
    and add_step ind (Let (t1, t2)) =
        add_str (of_indent ind ^ "let ") #> add_term t1 #> add_str " = " #> add_term t2
        #> add_str "\n"
      | add_step ind (Prove (qs, xs, l, t, subs, (ls, ss), meth :: _, comment)) =
        add_step_pre ind qs subs
        #> (case xs of
            [] => add_str (of_have qs (length subs) ^ " ")
          | _ =>
            add_str (of_obtain qs (length subs) ^ " ")
            #> add_frees xs
            #> add_str (" where\n" ^ of_indent (ind + 1)))
        #> add_str (of_label l)
        #> add_term (if is_thesis ctxt t then HOLogic.mk_Trueprop (Var thesis_var) else t)
        #> add_str ("\n" ^ of_indent (ind + 1) ^ of_method ls ss meth ^
          (if comment = "" then "" else " (* " ^ comment ^ " *)") ^ "\n")
    and add_steps ind = fold (add_step ind)
    and of_proof ind ctxt (Proof (xs, assms, steps)) =
      ("", ctxt)
      |> add_fix ind xs
      |> fold (add_assm ind) assms
      |> add_steps ind steps
      |> fst
  in
    (if i <> 1 then "prefer " ^ string_of_int i ^ "\n" else "") ^
    of_indent 0 ^ "proof -\n" ^ of_proof 1 ctxt proof ^
    of_indent 0 ^ (if n = 1 then "qed" else "next")
  end

end;
