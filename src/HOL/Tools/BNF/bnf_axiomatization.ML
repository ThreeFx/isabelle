(*  Title:      HOL/Tools/BNF/bnf_axiomatization.ML
    Author:     Dmitriy Traytel, TU Muenchen
    Copyright   2013

Axiomatic declaration of bounded natural functors.
*)

signature BNF_AXIOMATIZATION =
sig
  val bnf_axiomatization: (string -> bool) -> (binding option * (typ * sort)) list -> binding ->
    mixfix -> binding -> binding -> binding -> typ list -> local_theory ->
    BNF_Def.bnf * local_theory
end

structure BNF_Axiomatization : BNF_AXIOMATIZATION =
struct

open BNF_Util
open BNF_Def

fun prepare_decl prepare_plugins prepare_constraint prepare_typ
    raw_plugins raw_vars b mx user_mapb user_relb user_predb user_witTs lthy =
  let
   val plugins = prepare_plugins lthy raw_plugins;

   fun prepare_type_arg (set_opt, (ty, c)) =
      let val s = fst (dest_TFree (prepare_typ lthy ty)) in
        (set_opt, (s, prepare_constraint lthy c))
      end;
    val ((user_setbs, vars), raw_vars') =
      map prepare_type_arg raw_vars
      |> `split_list
      |>> apfst (map_filter I);
    val deads = map_filter (fn (NONE, x) => SOME x | _ => NONE) raw_vars';

    fun mk_b name user_b =
      (if Binding.is_empty user_b then Binding.prefix_name (name ^ "_") b else user_b)
      |> Binding.qualify false (Binding.name_of b);
    val (Tname, lthy) = Typedecl.basic_typedecl {final = true} (b, length vars, mx) lthy;
    val (bd_type_Tname, lthy) = lthy
      |> Typedecl.basic_typedecl {final = true} (mk_b "bd_type" Binding.empty, length deads, NoSyn);
    val T = Type (Tname, map TFree vars);
    val bd_type_T = Type (bd_type_Tname, map TFree deads);
    val lives = map TFree (filter_out (member (op =) deads) vars);
    val live = length lives;
    val _ = "Trying to declare a BNF with no live variables" |> null lives ? error;
    val (lives', _) = BNF_Util.mk_TFrees (length lives)
      (fold Variable.declare_typ (map TFree vars) lthy);
    val T' = Term.typ_subst_atomic (lives ~~ lives') T;
    val mapT = map2 (curry op -->) lives lives' ---> T --> T';
    val setTs = map (fn U => T --> HOLogic.mk_setT U) lives;
    val bdT = BNF_Util.mk_relT (bd_type_T, bd_type_T);
    val mapb = mk_b mapN user_mapb;
    val bdb = mk_b "bd" Binding.empty;
    val setbs = map2 (fn b => fn i => mk_b (mk_setN i) b) user_setbs
      (if live = 1 then [0] else 1 upto live);

    val witTs = map (prepare_typ lthy) user_witTs;
    val nwits = length witTs;
    val witbs = map (fn i => mk_b (mk_witN i) Binding.empty)
      (if nwits = 1 then [0] else 1 upto nwits);

    val lthy = Local_Theory.background_theory
      (Sign.add_consts ((mapb, mapT, NoSyn) :: (bdb, bdT, NoSyn) ::
        map2 (fn b => fn T => (b, T, NoSyn)) setbs setTs @
        map2 (fn b => fn T => (b, T, NoSyn)) witbs witTs))
      lthy;
    val Fmap = Const (Local_Theory.full_name lthy mapb, mapT);
    val Fsets = map2 (fn setb => fn setT =>
      Const (Local_Theory.full_name lthy setb, setT)) setbs setTs;
    val Fbd = Const (Local_Theory.full_name lthy bdb, bdT);
    val Fwits = map2 (fn witb => fn witT =>
      Const (Local_Theory.full_name lthy witb, witT)) witbs witTs;
    val (key, goals, (triv_tac_opt, wit_goalss), after_qed, lthy, _) =
      prepare_def Do_Inline (user_policy Note_Some) false I (K I) (K I) (SOME (map TFree deads))
      user_mapb user_relb user_predb user_setbs
      (((((((Binding.empty, T), Fmap), Fsets), Fbd), Fwits), NONE), NONE)
      lthy;

    fun mk_wits_tac ctxt set_maps = TRYALL Goal.conjunction_tac THEN the triv_tac_opt ctxt set_maps;
    val wit_goals = map Logic.mk_conjunction_balanced wit_goalss;
    val all_goalss = map single goals @ (if nwits > 0 then wit_goalss else []);

    val (((_, raw_thms)), lthy) = Local_Theory.background_theory_result
      (Specification.axiomatization [] [] []
        (map_index (fn (i, ax) =>
          ((mk_b ("axiom" ^ string_of_int (i + 1)) Binding.empty, []), ax)) (flat all_goalss))) lthy;

    fun mk_wit_thms set_maps =
      Goal.prove_sorry lthy [] [] (Logic.mk_conjunction_balanced wit_goals)
        (fn {context = ctxt, prems = _} => mk_wits_tac ctxt set_maps)
      |> Thm.close_derivation
      |> Conjunction.elim_balanced (length wit_goals)
      |> map2 (Conjunction.elim_balanced o length) wit_goalss
      |> (map o map) (Thm.forall_elim_vars 0);
    val phi = Local_Theory.target_morphism lthy;
    val thms = unflat all_goalss (Morphism.fact phi raw_thms);

    val (bnf, lthy') = after_qed mk_wit_thms thms lthy
  in
    (bnf, register_bnf plugins key bnf lthy')
  end;

val bnf_axiomatization = prepare_decl (K I) (K I) (K I);

fun read_constraint _ NONE = \<^sort>\<open>type\<close>
  | read_constraint ctxt (SOME s) = Syntax.read_sort ctxt s;

val bnf_axiomatization_cmd = prepare_decl Plugin_Name.make_filter read_constraint Syntax.read_typ;

val parse_witTs =
  \<^keyword>\<open>[\<close> |-- (Parse.name --| \<^keyword>\<open>:\<close> -- Scan.repeat Parse.typ
    >> (fn ("wits", Ts) => Ts
         | (s, _) => error ("Unknown label " ^ quote s ^ " (expected \"wits\")"))) --|
  \<^keyword>\<open>]\<close> || Scan.succeed [];

val parse_bnf_axiomatization_options =
  Scan.optional (\<^keyword>\<open>(\<close> |-- Plugin_Name.parse_filter --| \<^keyword>\<open>)\<close>) (K (K true));

val parse_bnf_axiomatization =
  parse_bnf_axiomatization_options -- parse_type_args_named_constrained -- Parse.binding --
  parse_witTs -- Parse.opt_mixfix -- parse_map_rel_pred_bindings;

val _ =
  Outer_Syntax.local_theory \<^command_keyword>\<open>bnf_axiomatization\<close> "bnf declaration"
    (parse_bnf_axiomatization >>
      (fn (((((plugins, bsTs), b), witTs), mx), (mapb, relb, predb)) =>
         bnf_axiomatization_cmd plugins bsTs b mx mapb relb predb witTs #> snd));

end;
