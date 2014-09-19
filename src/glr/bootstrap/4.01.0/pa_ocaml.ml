open Input
open Decap
open Charset
open Asttypes
open Parsetree
open Longident
include Pa_ocaml_prelude
let _ = ()
module Make(Initial:Extension) =
  struct
    include Initial
    let mk_unary_opp name _loc_name arg _loc_arg =
      let res =
        match (name, (arg.pexp_desc)) with
        | ("-",Pexp_constant (Const_int n)) ->
            Pexp_constant (Const_int (- n))
        | ("-",Pexp_constant (Const_int32 n)) ->
            Pexp_constant (Const_int32 (Int32.neg n))
        | ("-",Pexp_constant (Const_int64 n)) ->
            Pexp_constant (Const_int64 (Int64.neg n))
        | ("-",Pexp_constant (Const_nativeint n)) ->
            Pexp_constant (Const_nativeint (Nativeint.neg n))
        | (("-"|"-."),Pexp_constant (Const_float f)) ->
            Pexp_constant (Const_float ("-" ^ f))
        | ("+",Pexp_constant (Const_int _))
          |("+",Pexp_constant (Const_int32 _))
          |("+",Pexp_constant (Const_int64 _))
          |("+",Pexp_constant (Const_nativeint _))
          |(("+"|"+."),Pexp_constant (Const_float _)) -> arg.pexp_desc
        | (("-"|"-."|"+"|"+."),_) ->
            let p =
              loc_expr _loc_name
                (Pexp_ident (id_loc (Lident ("~" ^ name)) _loc_name)) in
            Pexp_apply (p, [("", arg)])
        | _ ->
            let p =
              loc_expr _loc_name
                (Pexp_ident (id_loc (Lident name) _loc_name)) in
            Pexp_apply (p, [("", arg)]) in
      loc_expr (merge2 _loc_name _loc_arg) res
    let check_variable vl loc v =
      if List.mem v vl
      then raise (let open Syntaxerr in Error (Variable_in_scope (loc, v)))
    let varify_constructors var_names t =
      let rec loop t =
        let desc =
          match t.ptyp_desc with
          | Ptyp_any  -> Ptyp_any
          | Ptyp_var x -> (check_variable var_names t.ptyp_loc x; Ptyp_var x)
          | Ptyp_arrow (label,core_type,core_type') ->
              Ptyp_arrow (label, (loop core_type), (loop core_type'))
          | Ptyp_tuple lst -> Ptyp_tuple (List.map loop lst)
          | Ptyp_constr ({ txt = Lident s },[]) when List.mem s var_names ->
              Ptyp_var s
          | Ptyp_constr (longident,lst) ->
              Ptyp_constr (longident, (List.map loop lst))
          | Ptyp_object lst -> Ptyp_object (List.map loop_core_field lst)
          | Ptyp_class (longident,lst,lbl_list) ->
              Ptyp_class (longident, (List.map loop lst), lbl_list)
          | Ptyp_alias (core_type,string) ->
              (check_variable var_names t.ptyp_loc string;
               Ptyp_alias ((loop core_type), string))
          | Ptyp_variant (row_field_list,flag,lbl_lst_option) ->
              Ptyp_variant
                ((List.map loop_row_field row_field_list), flag,
                  lbl_lst_option)
          | Ptyp_poly (string_lst,core_type) ->
              (List.iter (check_variable var_names t.ptyp_loc) string_lst;
               Ptyp_poly (string_lst, (loop core_type)))
          | Ptyp_package (longident,lst) ->
              Ptyp_package
                (longident, (List.map (fun (n,typ)  -> (n, (loop typ))) lst)) in
        { t with ptyp_desc = desc }
      and loop_core_field t =
        let desc =
          match t.pfield_desc with
          | Pfield (n,typ) -> Pfield (n, (loop typ))
          | Pfield_var  -> Pfield_var in
        { t with pfield_desc = desc }
      and loop_row_field =
        function
        | Rtag (label,flag,lst) -> Rtag (label, flag, (List.map loop lst))
        | Rinherit t -> Rinherit (loop t) in
      loop t
    let wrap_type_annotation _loc newtypes core_type body =
      let exp = loc_expr _loc (pexp_constraint (body, core_type)) in
      let exp =
        List.fold_right
          (fun newtype  exp  -> loc_expr _loc (Pexp_newtype (newtype, exp)))
          newtypes exp in
      (exp,
        (loc_typ _loc
           (Ptyp_poly (newtypes, (varify_constructors newtypes core_type)))))
    let float_lit_dec = "[0-9][0-9_]*[.][0-9_]*\\([eE][+-][0-9][0-9_]*\\)?"
    let float_lit_no_dec = "[0-9][0-9_]*[eE][+-]?[0-9][0-9_]*"
    let float_re = union_re [float_lit_no_dec; float_lit_dec]
    let float_literal =
      Decap.alternatives'
        [Decap.apply (fun f  -> f)
           (Decap.regexp ~name:"float" float_re (fun groupe  -> groupe 0));
        Decap.fsequence (Decap.char '$' '$')
          (Decap.fsequence (Decap.string "float" "float")
             (Decap.fsequence (Decap.char ':' ':')
                (Decap.sequence (expression_lvl (next_exp App))
                   (Decap.char '$' '$')
                   (fun e  _  _  _  _  -> string_of_float (push_pop_float e)))))]
    let char_regular = "[^\\']"
    let string_regular = "[^\\\"]"
    let char_escaped = "[\\\\][\\\\\\\"\\'ntbrs ]"
    let char_dec = "[\\\\][0-9][0-9][0-9]"
    let char_hex = "[\\\\][x][0-9a-fA-F][0-9a-fA-F]"
    exception Illegal_escape of string
    let one_char is_char =
      Decap.alternatives'
        (let y = (Decap.apply (fun c  -> '\n') (Decap.char '\n' '\n')) ::
           (let y =
              [Decap.apply
                 (fun c  ->
                    match c.[1] with
                    | 'n' -> '\n'
                    | 't' -> '\t'
                    | 'b' -> '\b'
                    | 'r' -> '\r'
                    | 's' -> ' '
                    | c -> c)
                 (Decap.regexp ~name:"char_escaped" char_escaped
                    (fun groupe  -> groupe 0));
              Decap.apply
                (fun c  ->
                   let str = String.sub c 1 3 in
                   let i = Scanf.sscanf str "%i" (fun i  -> i) in
                   if i > 255
                   then raise (Illegal_escape str)
                   else char_of_int i)
                (Decap.regexp ~name:"char_dec" char_dec
                   (fun groupe  -> groupe 0));
              Decap.apply
                (fun c  ->
                   let str = String.sub c 2 2 in
                   let str' = String.concat "" ["0x"; str] in
                   let i = Scanf.sscanf str' "%i" (fun i  -> i) in
                   char_of_int i)
                (Decap.regexp ~name:"char_hex" char_hex
                   (fun groupe  -> groupe 0))] in
            if not is_char
            then
              (Decap.apply (fun c  -> c.[0])
                 (Decap.regexp ~name:"string_regular" string_regular
                    (fun groupe  -> groupe 0)))
              :: y
            else y) in
         if is_char
         then
           (Decap.apply (fun c  -> c.[0])
              (Decap.regexp ~name:"char_regular" char_regular
                 (fun groupe  -> groupe 0)))
           :: y
         else y)
    let char_literal =
      Decap.alternatives'
        [Decap.apply (fun r  -> r)
           (change_layout
              (Decap.fsequence (Decap.char '\'' '\'')
                 (Decap.sequence (one_char true) (Decap.char '\'' '\'')
                    (fun c  _  _  -> c))) no_blank);
        Decap.fsequence (Decap.char '$' '$')
          (Decap.fsequence (Decap.string "char" "char")
             (Decap.fsequence (Decap.char ':' ':')
                (Decap.sequence (expression_lvl (next_exp App))
                   (Decap.char '$' '$')
                   (fun e  _  _  _  _  -> push_pop_char e))))]
    let interspace = "[ \t]*"
    let string_literal =
      let char_list_to_string lc =
        let len = List.length lc in
        let str = String.create len in
        let ptr = ref lc in
        for i = 0 to len - 1 do
          (match !ptr with
           | [] -> assert false
           | x::l -> (String.unsafe_set str i x; ptr := l))
        done;
        str in
      Decap.alternatives'
        [Decap.apply (fun r  -> r)
           (change_layout
              (Decap.fsequence (Decap.char '"' '"')
                 (Decap.fsequence
                    (Decap.apply List.rev
                       (Decap.fixpoint []
                          (Decap.apply (fun x  l  -> x :: l) (one_char false))))
                    (Decap.sequence
                       (Decap.apply List.rev
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                (Decap.fsequence (Decap.char '\\' '\\')
                                   (Decap.fsequence (Decap.char '\n' '\n')
                                      (Decap.sequence
                                         (Decap.regexp ~name:"interspace"
                                            interspace
                                            (fun groupe  -> groupe 0))
                                         (Decap.apply List.rev
                                            (Decap.fixpoint []
                                               (Decap.apply
                                                  (fun x  l  -> x :: l)
                                                  (one_char false))))
                                         (fun _  lc  _  _  -> lc)))))))
                       (Decap.char '"' '"')
                       (fun lcs  _  lc  _  ->
                          char_list_to_string (List.flatten (lc :: lcs))))))
              no_blank);
        Decap.apply (fun r  -> r)
          (change_layout
             (Decap.iter
                (Decap.fsequence (Decap.char '{' '{')
                   (Decap.sequence
                      (Decap.regexp "[a-z]*" (fun groupe  -> groupe 0))
                      (Decap.char '|' '|')
                      (fun id  _  _  ->
                         let string_literal_suit =
                           declare_grammar "string_literal_suit" in
                         let _ =
                           set_grammar string_literal_suit
                             (Decap.alternatives'
                                [Decap.fsequence (Decap.char '|' '|')
                                   (Decap.sequence (Decap.string id id)
                                      (Decap.char '}' '}')
                                      (fun _  _  _  -> []));
                                Decap.sequence Decap.any string_literal_suit
                                  (fun c  r  -> c :: r)]) in
                         Decap.apply (fun r  -> char_list_to_string r)
                           string_literal_suit)))) no_blank);
        Decap.fsequence (Decap.char '$' '$')
          (Decap.fsequence (Decap.string "string" "string")
             (Decap.fsequence (Decap.char ':' ':')
                (Decap.sequence (expression_lvl (next_exp App))
                   (Decap.char '$' '$')
                   (fun e  _  _  _  _  -> push_pop_string e))))]
    let quotation = declare_grammar "quotation"
    let _ =
      set_grammar quotation
        (change_layout
           (Decap.alternatives'
              [Decap.fsequence (Decap.string "<:" "<:")
                 (Decap.sequence quotation quotation
                    (fun q  q'  _  -> "<:" ^ (q ^ (">>" ^ q'))));
              Decap.sequence string_literal quotation
                (fun s  q  -> (Printf.sprintf "%S" s) ^ q);
              Decap.apply (fun _  -> "") (Decap.string ">>" ">>");
              Decap.sequence (one_char false) quotation
                (fun c  q  -> (String.make 1 c) ^ q)]) no_blank)
    let label_name = lowercase_ident
    let label =
      Decap.sequence (Decap.string "~" "~") label_name (fun _  ln  -> ln)
    let opt_label =
      Decap.sequence (Decap.string "?" "?") label_name (fun _  ln  -> ln)
    let maybe_opt_label =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x) (Decap.string "?" "?")))
        label_name (fun o  ln  -> if o = None then ln else "?" ^ ln)
    let infix_op = Decap.apply (fun sym  -> sym) infix_symbol
    let operator_name =
      Decap.alternatives'
        [Decap.apply (fun op  -> op) infix_op;
        Decap.apply (fun op  -> op) prefix_symbol]
    let value_name =
      Decap.alternatives'
        [Decap.apply (fun id  -> id) lowercase_ident;
        Decap.fsequence (Decap.string "(" "(")
          (Decap.sequence operator_name (Decap.string ")" ")")
             (fun op  _  _  -> op))]
    let constr_name = capitalized_ident
    let tag_name =
      Decap.sequence (Decap.string "`" "`") ident (fun _  c  -> c)
    let typeconstr_name = lowercase_ident
    let field_name = lowercase_ident
    let module_name = capitalized_ident
    let modtype_name = ident
    let class_name = lowercase_ident
    let inst_var_name = lowercase_ident
    let method_name = lowercase_ident
    let (module_path_gen,set_module_path_gen) =
      grammar_family "module_path_gen"
    let (module_path_suit,set_module_path_suit) =
      grammar_family "module_path_suit"
    let module_path_suit_aux =
      memoize1
        (fun allow_app  ->
           Decap.alternatives'
             (let y =
                [Decap.sequence (Decap.string "." ".") module_name
                   (fun _  m  acc  -> Ldot (acc, m))] in
              if allow_app
              then
                (Decap.fsequence (Decap.string "(" "(")
                   (Decap.sequence (module_path_gen true)
                      (Decap.string ")" ")")
                      (fun m'  _  _  a  -> Lapply (a, m'))))
                :: y
              else y))
    let _ =
      set_module_path_suit
        (fun allow_app  ->
           Decap.alternatives'
             [Decap.sequence (module_path_suit_aux allow_app)
                (module_path_suit allow_app) (fun f  g  acc  -> g (f acc));
             Decap.apply (fun _  acc  -> acc) (Decap.empty ())])
    let _ =
      set_module_path_gen
        (fun allow_app  ->
           Decap.sequence module_name (module_path_suit allow_app)
             (fun m  s  -> s (Lident m)))
    let module_path = module_path_gen false
    let extended_module_path = module_path_gen true
    let value_path =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) value_name
        (fun mp  vn  ->
           match mp with | None  -> Lident vn | Some p -> Ldot (p, vn))
    let constr =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) constr_name
        (fun mp  cn  ->
           match mp with | None  -> Lident cn | Some p -> Ldot (p, cn))
    let typeconstr =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence extended_module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) typeconstr_name
        (fun mp  tcn  ->
           match mp with | None  -> Lident tcn | Some p -> Ldot (p, tcn))
    let field =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) field_name
        (fun mp  fn  ->
           match mp with | None  -> Lident fn | Some p -> Ldot (p, fn))
    let class_path =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) class_name
        (fun mp  cn  ->
           match mp with | None  -> Lident cn | Some p -> Ldot (p, cn))
    let modtype_path =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence extended_module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) modtype_name
        (fun mp  mtn  ->
           match mp with | None  -> Lident mtn | Some p -> Ldot (p, mtn))
    let classtype_path =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence extended_module_path (Decap.string "." ".")
                 (fun m  _  -> m)))) class_name
        (fun mp  cn  ->
           match mp with | None  -> Lident cn | Some p -> Ldot (p, cn))
    let opt_variance =
      Decap.apply
        (fun v  ->
           match v with
           | None  -> (false, false)
           | Some "+" -> (true, false)
           | Some "-" -> (false, true)
           | _ -> assert false)
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.regexp "[+-]" (fun groupe  -> groupe 0))))
    let override_flag =
      Decap.apply (fun o  -> if o <> None then Override else Fresh)
        (Decap.option None
           (Decap.apply (fun x  -> Some x) (Decap.string "!" "!")))
    let attr_id =
      Decap.sequence_position
        (Decap.regexp ~name:"ident" ident_re (fun groupe  -> groupe 0))
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.sequence (Decap.char '.' '.')
                    (Decap.regexp ~name:"ident" ident_re
                       (fun groupe  -> groupe 0)) (fun _  id  -> id)))))
        (fun id  l  __loc__start__buf  __loc__start__pos  __loc__end__buf 
           __loc__end__pos  ->
           let _loc =
             locate2 __loc__start__buf __loc__start__pos __loc__end__buf
               __loc__end__pos in
           id_loc (String.concat "." (id :: l)) _loc)
    type attr =  
      | PStr of structure_item list
      | PTyp of core_type
      | PPat of pattern* expression option 
    let payload =
      Decap.alternatives'
        [Decap.apply (fun s  -> PStr s) structure;
        Decap.sequence (Decap.char ':' ':') typexpr (fun _  t  -> PTyp t);
        Decap.fsequence (Decap.char '?' '?')
          (Decap.sequence pattern
             (Decap.option None
                (Decap.apply (fun x  -> Some x)
                   (Decap.sequence (Decap.string "when" "when") expression
                      (fun _  e  -> e)))) (fun p  e  _  -> PPat (p, e)))]
    let attribute =
      Decap.fsequence (Decap.string "[@" "[@")
        (Decap.sequence attr_id payload (fun id  p  _  -> (id, p)))
    let attributes =
      Decap.apply (fun _  -> ())
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.apply (fun a  -> a) attribute))))
    let ext_attributes =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence (Decap.char '%' '%') attribute (fun _  a  -> a))))
        attributes (fun a  l  -> (a, l))
    let post_item_attributes =
      Decap.apply (fun l  -> l)
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.fsequence (Decap.string "[@@" "[@@")
                    (Decap.fsequence attr_id
                       (Decap.sequence payload (Decap.char ']' ']')
                          (fun p  _  id  _  -> (id, p))))))))
    let ext_attributes =
      Decap.apply (fun l  -> l)
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.fsequence (Decap.string "[@@@" "[@@@")
                    (Decap.fsequence attr_id
                       (Decap.sequence payload (Decap.char ']' ']')
                          (fun p  _  id  _  -> (id, p))))))))
    let extension =
      Decap.fsequence (Decap.string "[%" "[%")
        (Decap.fsequence attr_id
           (Decap.sequence payload (Decap.char ']' ']')
              (fun p  _  id  _  -> (id, p))))
    let item_extension =
      Decap.fsequence (Decap.string "[%%" "[%%")
        (Decap.fsequence attr_id
           (Decap.sequence payload (Decap.char ']' ']')
              (fun p  _  id  _  -> (id, p))))
    let poly_typexpr =
      Decap.alternatives'
        [Decap.fsequence_position
           (Decap.sequence
              (Decap.sequence (Decap.string "'" "'") ident (fun _  id  -> id))
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l)
                    (Decap.sequence (Decap.string "'" "'") ident
                       (fun _  id  -> id)))) (fun x  l  -> x :: (List.rev l)))
           (Decap.sequence (Decap.string "." ".") typexpr
              (fun _  te  ids  __loc__start__buf  __loc__start__pos 
                 __loc__end__buf  __loc__end__pos  ->
                 let _loc =
                   locate2 __loc__start__buf __loc__start__pos
                     __loc__end__buf __loc__end__pos in
                 loc_typ _loc (Ptyp_poly (ids, te))));
        Decap.apply_position
          (fun te  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             loc_typ _loc (Ptyp_poly ([], te))) typexpr]
    let poly_syntax_typexpr =
      Decap.fsequence type_kw
        (Decap.fsequence
           (Decap.sequence typeconstr_name
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l) typeconstr_name))
              (fun x  l  -> x :: (List.rev l)))
           (Decap.sequence (Decap.string "." ".") typexpr
              (fun _  te  ids  _  -> (ids, te))))
    let method_type =
      Decap.fsequence_position method_name
        (Decap.sequence (Decap.string ":" ":") poly_typexpr
           (fun _  pte  mn  __loc__start__buf  __loc__start__pos 
              __loc__end__buf  __loc__end__pos  ->
              let _loc =
                locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                  __loc__end__pos in
              { pfield_desc = (Pfield (mn, pte)); pfield_loc = _loc }))
    let tag_spec =
      Decap.alternatives'
        [Decap.sequence tag_name
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.fsequence of_kw
                    (Decap.sequence
                       (Decap.option None
                          (Decap.apply (fun x  -> Some x)
                             (Decap.char '&' '&'))) typexpr
                       (fun amp  te  _  -> (amp, te))))))
           (fun tn  te  ->
              let (amp,t) =
                match te with
                | None  -> (true, [])
                | Some (amp,l) -> ((amp <> None), [l]) in
              Rtag (tn, amp, t));
        Decap.apply (fun te  -> Rinherit te) typexpr]
    let tag_spec_first =
      Decap.alternatives'
        [Decap.sequence tag_name
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.fsequence of_kw
                    (Decap.sequence
                       (Decap.option None
                          (Decap.apply (fun x  -> Some x)
                             (Decap.char '&' '&'))) typexpr
                       (fun amp  te  _  -> (amp, te))))))
           (fun tn  te  ->
              let (amp,t) =
                match te with
                | None  -> (true, [])
                | Some (amp,l) -> ((amp <> None), [l]) in
              [Rtag (tn, amp, t)]);
        Decap.fsequence
          (Decap.option None (Decap.apply (fun x  -> Some x) typexpr))
          (Decap.sequence (Decap.string "|" "|") tag_spec
             (fun _  ts  te  ->
                match te with | None  -> [ts] | Some te -> [Rinherit te; ts]))]
    let tag_spec_full =
      Decap.alternatives'
        [Decap.sequence tag_name
           (Decap.option (true, [])
              (Decap.fsequence of_kw
                 (Decap.fsequence
                    (Decap.option None
                       (Decap.apply (fun x  -> Some x) (Decap.string "&" "&")))
                    (Decap.sequence typexpr
                       (Decap.apply List.rev
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                (Decap.sequence (Decap.string "&" "&")
                                   typexpr (fun _  te  -> te)))))
                       (fun te  tes  amp  _  -> ((amp <> None), (te :: tes)))))))
           (fun tn  (amp,tes)  -> Rtag (tn, amp, tes));
        Decap.apply (fun te  -> Rinherit te) typexpr]
    let polymorphic_variant_type: core_type grammar =
      Decap.alternatives'
        [Decap.fsequence_position (Decap.string "[" "[")
           (Decap.fsequence tag_spec_first
              (Decap.sequence
                 (Decap.apply List.rev
                    (Decap.fixpoint []
                       (Decap.apply (fun x  l  -> x :: l)
                          (Decap.sequence (Decap.string "|" "|") tag_spec
                             (fun _  ts  -> ts))))) (Decap.string "]" "]")
                 (fun tss  _  tsf  _  __loc__start__buf  __loc__start__pos 
                    __loc__end__buf  __loc__end__pos  ->
                    let _loc =
                      locate2 __loc__start__buf __loc__start__pos
                        __loc__end__buf __loc__end__pos in
                    let flag = true in
                    loc_typ _loc (Ptyp_variant ((tsf @ tss), flag, None)))));
        Decap.fsequence_position (Decap.string "[>" "[>")
          (Decap.fsequence
             (Decap.option None (Decap.apply (fun x  -> Some x) tag_spec))
             (Decap.sequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string "|" "|") tag_spec
                            (fun _  ts  -> ts))))) (Decap.string "]" "]")
                (fun tss  _  ts  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   let tss =
                     match ts with | None  -> tss | Some ts -> ts :: tss in
                   let flag = false in
                   loc_typ _loc (Ptyp_variant (tss, flag, None)))));
        Decap.fsequence_position (Decap.string "[<" "[<")
          (Decap.fsequence
             (Decap.option None
                (Decap.apply (fun x  -> Some x) (Decap.string "|" "|")))
             (Decap.fsequence tag_spec_full
                (Decap.fsequence
                   (Decap.apply List.rev
                      (Decap.fixpoint []
                         (Decap.apply (fun x  l  -> x :: l)
                            (Decap.sequence (Decap.string "|" "|")
                               tag_spec_full (fun _  tsf  -> tsf)))))
                   (Decap.sequence
                      (Decap.option []
                         (Decap.sequence (Decap.string ">" ">")
                            (Decap.sequence tag_name
                               (Decap.fixpoint []
                                  (Decap.apply (fun x  l  -> x :: l) tag_name))
                               (fun x  l  -> x :: (List.rev l)))
                            (fun _  tns  -> tns))) (Decap.string "]" "]")
                      (fun tns  _  tfss  tfs  _  _  __loc__start__buf 
                         __loc__start__pos  __loc__end__buf  __loc__end__pos 
                         ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         let flag = true in
                         loc_typ _loc
                           (Ptyp_variant ((tfs :: tfss), flag, (Some tns))))))))]
    let package_constraint =
      Decap.fsequence type_kw
        (Decap.fsequence (locate typeconstr)
           (Decap.sequence (Decap.char '=' '=') typexpr
              (fun _  te  tc  ->
                 let (_loc_tc,tc) = tc in
                 fun _  -> let tc = id_loc tc _loc_tc in (tc, te))))
    let package_type =
      Decap.sequence (locate modtype_path)
        (Decap.option []
           (Decap.fsequence with_kw
              (Decap.sequence package_constraint
                 (Decap.apply List.rev
                    (Decap.fixpoint []
                       (Decap.apply (fun x  l  -> x :: l)
                          (Decap.sequence and_kw package_constraint
                             (fun _  pc  -> pc)))))
                 (fun pc  pcs  _  -> pc :: pcs))))
        (fun mtp  ->
           let (_loc_mtp,mtp) = mtp in
           fun cs  -> let mtp = id_loc mtp _loc_mtp in Ptyp_package (mtp, cs))
    let opt_present =
      Decap.alternatives'
        [Decap.fsequence (Decap.string "[>" "[>")
           (Decap.sequence
              (Decap.sequence tag_name
                 (Decap.fixpoint []
                    (Decap.apply (fun x  l  -> x :: l) tag_name))
                 (fun x  l  -> x :: (List.rev l))) (Decap.string "]" "]")
              (fun l  _  _  -> l));
        Decap.apply (fun _  -> []) (Decap.empty ())]
    let mkoption loc d =
      let loc = ghost loc in
      loc_typ loc
        (Ptyp_constr
           ((id_loc (Ldot ((Lident "*predef*"), "option")) loc), [d]))
    let typexpr_base: core_type grammar =
      Decap.alternatives'
        [Decap.apply (fun e  -> e) (alternatives extra_types);
        Decap.sequence_position (Decap.string "'" "'") ident
          (fun _  id  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             loc_typ _loc (Ptyp_var id));
        Decap.apply_position
          (fun _  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             loc_typ _loc Ptyp_any) (Decap.string "_" "_");
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence module_kw
             (Decap.sequence package_type (Decap.string ")" ")")
                (fun pt  _  _  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   loc_typ _loc pt)));
        Decap.fsequence (Decap.string "(" "(")
          (Decap.sequence typexpr (Decap.string ")" ")")
             (fun te  _  _  -> te));
        Decap.fsequence_position opt_label
          (Decap.fsequence (Decap.string ":" ":")
             (Decap.fsequence (locate (typexpr_lvl (next_type_prio Arr)))
                (Decap.sequence (Decap.string "->" "->") typexpr
                   (fun _  te'  te  ->
                      let (_loc_te,te) = te in
                      fun _  ln  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        loc_typ _loc
                          (Ptyp_arrow
                             (("?" ^ ln), (mkoption _loc_te te), te'))))));
        Decap.fsequence_position label_name
          (Decap.fsequence (Decap.string ":" ":")
             (Decap.fsequence (typexpr_lvl (next_type_prio Arr))
                (Decap.sequence (Decap.string "->" "->") typexpr
                   (fun _  te'  te  _  ln  __loc__start__buf 
                      __loc__start__pos  __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      loc_typ _loc (Ptyp_arrow (ln, te, te'))))));
        Decap.apply_position
          (fun tc  ->
             let (_loc_tc,tc) = tc in
             fun __loc__start__buf  __loc__start__pos  __loc__end__buf 
               __loc__end__pos  ->
               let _loc =
                 locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                   __loc__end__pos in
               loc_typ _loc (Ptyp_constr ((id_loc tc _loc_tc), [])))
          (locate typeconstr);
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence typexpr
             (Decap.fsequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string "," ",") typexpr
                            (fun _  te  -> te)))))
                (Decap.sequence (Decap.string ")" ")") (locate typeconstr)
                   (fun _  tc  ->
                      let (_loc_tc,tc) = tc in
                      fun tes  te  _  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let constr = id_loc tc _loc_tc in
                        loc_typ _loc (Ptyp_constr (constr, (te :: tes)))))));
        Decap.apply (fun pvt  -> pvt) polymorphic_variant_type;
        Decap.fsequence_position (Decap.string "<" "<")
          (Decap.sequence
             (locate
                (Decap.option None
                   (Decap.apply (fun x  -> Some x) (Decap.string ".." ".."))))
             (Decap.string ">" ">")
             (fun rv  ->
                let (_loc_rv,rv) = rv in
                fun _  _  __loc__start__buf  __loc__start__pos 
                  __loc__end__buf  __loc__end__pos  ->
                  let _loc =
                    locate2 __loc__start__buf __loc__start__pos
                      __loc__end__buf __loc__end__pos in
                  let ml =
                    if rv = None
                    then []
                    else [{ pfield_desc = Pfield_var; pfield_loc = _loc_rv }] in
                  loc_typ _loc (Ptyp_object ml)));
        Decap.fsequence_position (Decap.string "<" "<")
          (Decap.fsequence method_type
             (Decap.fsequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string ";" ";") method_type
                            (fun _  mt  -> mt)))))
                (Decap.sequence
                   (locate
                      (Decap.option None
                         (Decap.apply (fun x  -> Some x)
                            (Decap.sequence (Decap.string ";" ";")
                               (Decap.option None
                                  (Decap.apply (fun x  -> Some x)
                                     (Decap.string ".." "..")))
                               (fun _  rv  -> rv))))) (Decap.string ">" ">")
                   (fun rv  ->
                      let (_loc_rv,rv) = rv in
                      fun _  mts  mt  _  __loc__start__buf  __loc__start__pos
                         __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let ml =
                          if (rv = None) || (rv = (Some None))
                          then []
                          else
                            [{ pfield_desc = Pfield_var; pfield_loc = _loc_rv
                             }] in
                        loc_typ _loc (Ptyp_object ((mt :: mts) @ ml))))));
        Decap.fsequence_position (Decap.string "#" "#")
          (Decap.sequence (locate class_path) opt_present
             (fun cp  ->
                let (_loc_cp,cp) = cp in
                fun o  _  __loc__start__buf  __loc__start__pos 
                  __loc__end__buf  __loc__end__pos  ->
                  let _loc =
                    locate2 __loc__start__buf __loc__start__pos
                      __loc__end__buf __loc__end__pos in
                  let cp = id_loc cp _loc_cp in
                  loc_typ _loc (Ptyp_class (cp, [], o))));
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence typexpr
             (Decap.fsequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string "," ",") typexpr
                            (fun _  te  -> te)))))
                (Decap.fsequence (Decap.string ")" ")")
                   (Decap.fsequence (Decap.string "#" "#")
                      (Decap.sequence (locate class_path) opt_present
                         (fun cp  ->
                            let (_loc_cp,cp) = cp in
                            fun o  _  _  tes  te  _  __loc__start__buf 
                              __loc__start__pos  __loc__end__buf 
                              __loc__end__pos  ->
                              let _loc =
                                locate2 __loc__start__buf __loc__start__pos
                                  __loc__end__buf __loc__end__pos in
                              let cp = id_loc cp _loc_cp in
                              loc_typ _loc (Ptyp_class (cp, (te :: tes), o))))))));
        Decap.fsequence_position (Decap.char '$' '$')
          (Decap.fsequence
             (Decap.option None
                (Decap.apply (fun x  -> Some x)
                   (Decap.sequence
                      (Decap.apply (fun _  -> "tuple")
                         (Decap.string "tuple" "tuple")) (Decap.char ':' ':')
                      (fun t  _  -> t))))
             (Decap.sequence (expression_lvl (next_exp App))
                (Decap.char '$' '$')
                (fun e  _  t  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   match t with
                   | None  -> push_pop_type e
                   | Some str ->
                       let l = push_pop_type_list e in
                       (match str with
                        | "tuple" -> loc_typ _loc (Ptyp_tuple l)
                        | _ -> raise Give_up))))]
    let typexpr_suit_aux:
      type_prio ->
        type_prio ->
          (type_prio* (core_type -> Location.t -> core_type)) grammar
      =
      memoize1
        (fun lvl'  lvl  ->
           let ln f _loc e _loc_f = loc_typ (merge2 _loc_f _loc) e in
           Decap.alternatives'
             (let y =
                let y =
                  let y =
                    let y =
                      let y = [] in
                      if (lvl' >= DashType) && (lvl <= DashType)
                      then
                        (Decap.fsequence_position (Decap.string "#" "#")
                           (Decap.sequence (locate class_path) opt_present
                              (fun cp  ->
                                 let (_loc_cp,cp) = cp in
                                 fun o  _  __loc__start__buf 
                                   __loc__start__pos  __loc__end__buf 
                                   __loc__end__pos  ->
                                   let _loc =
                                     locate2 __loc__start__buf
                                       __loc__start__pos __loc__end__buf
                                       __loc__end__pos in
                                   let cp = id_loc cp _loc_cp in
                                   let tex te =
                                     ln te _loc (Ptyp_class (cp, [te], o)) in
                                   (DashType, tex))))
                        :: y
                      else y in
                    if (lvl' >= As) && (lvl <= As)
                    then
                      (Decap.fsequence_position as_kw
                         (Decap.sequence (Decap.string "'" "'") ident
                            (fun _  id  _  __loc__start__buf 
                               __loc__start__pos  __loc__end__buf 
                               __loc__end__pos  ->
                               let _loc =
                                 locate2 __loc__start__buf __loc__start__pos
                                   __loc__end__buf __loc__end__pos in
                               (As,
                                 (fun te  -> ln te _loc (Ptyp_alias (te, id)))))))
                      :: y
                    else y in
                  if (lvl' >= AppType) && (lvl <= AppType)
                  then
                    (Decap.apply_position
                       (fun tc  ->
                          let (_loc_tc,tc) = tc in
                          fun __loc__start__buf  __loc__start__pos 
                            __loc__end__buf  __loc__end__pos  ->
                            let _loc =
                              locate2 __loc__start__buf __loc__start__pos
                                __loc__end__buf __loc__end__pos in
                            (AppType,
                              (fun te  ->
                                 ln te _loc
                                   (Ptyp_constr ((id_loc tc _loc_tc), [te])))))
                       (locate typeconstr))
                    :: y
                  else y in
                if (lvl' > ProdType) && (lvl <= ProdType)
                then
                  (Decap.apply_position
                     (fun tes  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        (ProdType,
                          (fun te  -> ln te _loc (Ptyp_tuple (te :: tes)))))
                     (Decap.sequence
                        (Decap.sequence (Decap.string "*" "*")
                           (typexpr_lvl (next_type_prio ProdType))
                           (fun _  te  -> te))
                        (Decap.fixpoint []
                           (Decap.apply (fun x  l  -> x :: l)
                              (Decap.sequence (Decap.string "*" "*")
                                 (typexpr_lvl (next_type_prio ProdType))
                                 (fun _  te  -> te))))
                        (fun x  l  -> x :: (List.rev l))))
                  :: y
                else y in
              if (lvl' > Arr) && (lvl <= Arr)
              then
                (Decap.sequence_position (Decap.string "->" "->")
                   (typexpr_lvl Arr)
                   (fun _  te'  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      (Arr,
                        (fun te  -> ln te _loc (Ptyp_arrow ("", te, te'))))))
                :: y
              else y))
    let typexpr_suit =
      let f =
        memoize2'
          (fun type_suit  lvl'  lvl  ->
             Decap.alternatives'
               [Decap.iter
                  (Decap.apply
                     (fun (p1,f1)  ->
                        Decap.apply
                          (fun (p2,f2)  ->
                             (p2,
                               (fun f  _loc_f  -> f2 (f1 f _loc_f) _loc_f)))
                          (type_suit p1 lvl)) (typexpr_suit_aux lvl' lvl));
               Decap.apply (fun _  -> (lvl', (fun f  _loc_f  -> f)))
                 (Decap.empty ())]) in
      let rec res x y = f res x y in res
    let _ =
      set_typexpr_lvl
        (fun lvl  ->
           Decap.sequence (locate typexpr_base) (typexpr_suit AtomType lvl)
             (fun t  -> let (_loc_t,t) = t in fun ft  -> snd ft t _loc_t))
    let type_param =
      Decap.alternatives'
        [Decap.fsequence opt_variance
           (Decap.sequence (Decap.char '\'' '\'') (locate ident)
              (fun _  id  ->
                 let (_loc_id,id) = id in
                 fun var  -> ((Some (id_loc id _loc_id)), var)));
        Decap.sequence opt_variance (Decap.char '_' '_')
          (fun var  _  -> (None, var))]
    let type_params =
      Decap.alternatives'
        [Decap.apply (fun tp  -> [tp]) type_param;
        Decap.fsequence (Decap.string "(" "(")
          (Decap.fsequence type_param
             (Decap.sequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string "," ",") type_param
                            (fun _  tp  -> tp))))) (Decap.string ")" ")")
                (fun tps  _  tp  _  -> tp :: tps)))]
    let type_equation =
      Decap.fsequence (Decap.char '=' '=')
        (Decap.sequence private_flag typexpr (fun p  te  _  -> (p, te)))
    let type_constraint =
      Decap.fsequence_position constraint_kw
        (Decap.fsequence (Decap.string "'" "'")
           (Decap.fsequence (locate ident)
              (Decap.sequence (Decap.char '=' '=') typexpr
                 (fun _  te  id  ->
                    let (_loc_id,id) = id in
                    fun _  _  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      ((loc_typ _loc_id (Ptyp_var id)), te, _loc)))))
    let constr_decl =
      let constr_name =
        Decap.alternatives'
          [Decap.apply (fun cn  -> cn) constr_name;
          Decap.sequence (Decap.string "(" "(") (Decap.string ")" ")")
            (fun _  _  -> "()")] in
      Decap.sequence_position (locate constr_name)
        (Decap.alternatives'
           [Decap.apply
              (fun te  ->
                 let tes =
                   match te with
                   | None  -> []
                   | Some { ptyp_desc = Ptyp_tuple tes; ptyp_loc = _ } -> tes
                   | Some t -> [t] in
                 (tes, None))
              (Decap.option None
                 (Decap.apply (fun x  -> Some x)
                    (Decap.sequence of_kw typexpr (fun _  te  -> te))));
           Decap.fsequence (Decap.char ':' ':')
             (Decap.sequence
                (Decap.option []
                   (Decap.fsequence (typexpr_lvl (next_type_prio ProdType))
                      (Decap.sequence
                         (Decap.apply List.rev
                            (Decap.fixpoint []
                               (Decap.apply (fun x  l  -> x :: l)
                                  (Decap.sequence (Decap.char '*' '*')
                                     (typexpr_lvl (next_type_prio ProdType))
                                     (fun _  te  -> te)))))
                         (Decap.string "->" "->")
                         (fun tes  _  te  -> te :: tes)))) typexpr
                (fun ats  te  _  -> (ats, (Some te))))])
        (fun cn  ->
           let (_loc_cn,cn) = cn in
           fun (tes,te)  __loc__start__buf  __loc__start__pos 
             __loc__end__buf  __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             let c = id_loc cn _loc_cn in
             constructor_declaration _loc c tes te)
    let field_decl =
      Decap.fsequence_position mutable_flag
        (Decap.fsequence (locate field_name)
           (Decap.sequence (Decap.string ":" ":") poly_typexpr
              (fun _  pte  fn  ->
                 let (_loc_fn,fn) = fn in
                 fun m  __loc__start__buf  __loc__start__pos  __loc__end__buf
                    __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   label_declaration _loc (id_loc fn _loc_fn) m pte)))
    let type_representation =
      Decap.alternatives'
        [Decap.fsequence
           (Decap.option None
              (Decap.apply (fun x  -> Some x) (Decap.string "|" "|")))
           (Decap.sequence constr_decl
              (Decap.apply List.rev
                 (Decap.fixpoint []
                    (Decap.apply (fun x  l  -> x :: l)
                       (Decap.sequence (Decap.string "|" "|") constr_decl
                          (fun _  cd  -> cd)))))
              (fun cd  cds  _  -> Ptype_variant (cd :: cds)));
        Decap.fsequence (Decap.string "{" "{")
          (Decap.fsequence field_decl
             (Decap.fsequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string ";" ";") field_decl
                            (fun _  fd  -> fd)))))
                (Decap.sequence
                   (Decap.option None
                      (Decap.apply (fun x  -> Some x) (Decap.string ";" ";")))
                   (Decap.string "}" "}")
                   (fun _  _  fds  fd  _  -> Ptype_record (fd :: fds)))))]
    let type_information =
      Decap.fsequence
        (Decap.option None (Decap.apply (fun x  -> Some x) type_equation))
        (Decap.sequence
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.fsequence (Decap.char '=' '=')
                    (Decap.sequence private_flag type_representation
                       (fun pri  tr  _  -> (pri, tr))))))
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l) type_constraint)))
           (fun ptr  cstrs  te  ->
              let (pri,tkind) =
                match ptr with
                | None  -> (Public, Ptype_abstract)
                | Some c -> c in
              (pri, te, tkind, cstrs)))
    let typedef_gen ?prev_loc  constr filter =
      Decap.fsequence_position (Decap.option [] type_params)
        (Decap.sequence (locate constr) type_information
           (fun tcn  ->
              let (_loc_tcn,tcn) = tcn in
              fun ti  tps  __loc__start__buf  __loc__start__pos 
                __loc__end__buf  __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                let _loc =
                  match prev_loc with
                  | None  -> _loc
                  | Some l -> merge2 l _loc in
                let (pri,te,tkind,cstrs) = ti in
                let (pri,te) =
                  match te with
                  | None  -> (pri, None)
                  | Some (Private ,te) ->
                      (if pri = Private then raise Give_up;
                       (Private, (Some te)))
                  | Some (_,te) -> (pri, (Some te)) in
                ((id_loc tcn _loc_tcn),
                  (type_declaration _loc (id_loc (filter tcn) _loc_tcn) tps
                     cstrs tkind pri te))))
    let typedef = typedef_gen typeconstr_name (fun x  -> x)
    let typedef_in_constraint prev_loc =
      typedef_gen ~prev_loc typeconstr Longident.last
    let type_definition =
      Decap.fsequence type_kw
        (Decap.sequence typedef
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l)
                    (Decap.sequence and_kw typedef (fun _  td  -> td)))))
           (fun td  tds  _  -> td :: tds))
    let exception_declaration =
      Decap.fsequence exception_kw
        (Decap.sequence (locate constr_name)
           (locate
              (Decap.option None
                 (Decap.apply (fun x  -> Some x)
                    (Decap.sequence of_kw typexpr (fun _  te  -> te)))))
           (fun cn  ->
              let (_loc_cn,cn) = cn in
              fun te  ->
                let (_loc_te,te) = te in
                fun _  ->
                  let tes =
                    match te with
                    | None  -> []
                    | Some { ptyp_desc = Ptyp_tuple tes; ptyp_loc = _ } ->
                        tes
                    | Some t -> [t] in
                  ((id_loc cn _loc_cn), tes, (merge2 _loc_cn _loc_te))))
    let exception_definition =
      Decap.alternatives'
        [Decap.fsequence exception_kw
           (Decap.fsequence (locate constr_name)
              (Decap.sequence (Decap.char '=' '=') (locate constr)
                 (fun _  c  ->
                    let (_loc_c,c) = c in
                    fun cn  ->
                      let (_loc_cn,cn) = cn in
                      fun _  ->
                        let name = id_loc cn _loc_cn in
                        let ex = id_loc c _loc_c in
                        Pstr_exn_rebind (name, ex))));
        Decap.apply (fun (name,ed,_loc')  -> Pstr_exception (name, ed))
          exception_declaration]
    let class_field_spec = declare_grammar "class_field_spec"
    let class_body_type = declare_grammar "class_body_type"
    let virt_mut =
      Decap.alternatives'
        [Decap.sequence virtual_flag mutable_flag (fun v  m  -> (v, m));
        Decap.sequence mutable_kw virtual_kw
          (fun _  _  -> (Virtual, Mutable))]
    let virt_priv =
      Decap.alternatives'
        [Decap.sequence virtual_flag private_flag (fun v  p  -> (v, p));
        Decap.sequence private_kw virtual_kw
          (fun _  _  -> (Virtual, Private))]
    let _ =
      set_grammar class_field_spec
        (Decap.alternatives'
           [Decap.sequence_position inherit_kw class_body_type
              (fun _  cbt  __loc__start__buf  __loc__start__pos 
                 __loc__end__buf  __loc__end__pos  ->
                 let _loc =
                   locate2 __loc__start__buf __loc__start__pos
                     __loc__end__buf __loc__end__pos in
                 pctf_loc _loc (Pctf_inher cbt));
           Decap.fsequence_position val_kw
             (Decap.fsequence virt_mut
                (Decap.fsequence inst_var_name
                   (Decap.sequence (Decap.string ":" ":") typexpr
                      (fun _  te  ivn  (vir,mut)  _  __loc__start__buf 
                         __loc__start__pos  __loc__end__buf  __loc__end__pos 
                         ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         pctf_loc _loc (Pctf_val (ivn, mut, vir, te))))));
           Decap.fsequence_position method_kw
             (Decap.fsequence virt_priv
                (Decap.fsequence method_name
                   (Decap.sequence (Decap.string ":" ":") poly_typexpr
                      (fun _  te  mn  (v,pri)  _  __loc__start__buf 
                         __loc__start__pos  __loc__end__buf  __loc__end__pos 
                         ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         if v = Concrete
                         then pctf_loc _loc (Pctf_meth (mn, pri, te))
                         else pctf_loc _loc (Pctf_virt (mn, pri, te))))));
           Decap.fsequence_position constraint_kw
             (Decap.fsequence typexpr
                (Decap.sequence (Decap.char '=' '=') typexpr
                   (fun _  te'  te  _  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      pctf_loc _loc (Pctf_cstr (te, te')))))])
    let _ =
      set_grammar class_body_type
        (Decap.alternatives'
           [Decap.fsequence_position object_kw
              (Decap.fsequence
                 (locate
                    (Decap.option None
                       (Decap.apply (fun x  -> Some x)
                          (Decap.fsequence (Decap.string "(" "(")
                             (Decap.sequence typexpr (Decap.string ")" ")")
                                (fun te  _  _  -> te))))))
                 (Decap.sequence
                    (locate
                       (Decap.apply List.rev
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                class_field_spec)))) end_kw
                    (fun cfs  ->
                       let (_loc_cfs,cfs) = cfs in
                       fun _  te  ->
                         let (_loc_te,te) = te in
                         fun _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let self =
                             match te with
                             | None  -> loc_typ _loc_te Ptyp_any
                             | Some t -> t in
                           let sign =
                             {
                               pcsig_self = self;
                               pcsig_fields = cfs;
                               pcsig_loc = (merge2 _loc_te _loc_cfs)
                             } in
                           pcty_loc _loc (Pcty_signature sign))));
           Decap.sequence_position
             (Decap.option []
                (Decap.fsequence (Decap.string "[" "[")
                   (Decap.fsequence typexpr
                      (Decap.sequence
                         (Decap.apply List.rev
                            (Decap.fixpoint []
                               (Decap.apply (fun x  l  -> x :: l)
                                  (Decap.sequence (Decap.string "," ",")
                                     typexpr (fun _  te  -> te)))))
                         (Decap.string "]" "]")
                         (fun tes  _  te  _  -> te :: tes)))))
             (locate classtype_path)
             (fun tes  ctp  ->
                let (_loc_ctp,ctp) = ctp in
                fun __loc__start__buf  __loc__start__pos  __loc__end__buf 
                  __loc__end__pos  ->
                  let _loc =
                    locate2 __loc__start__buf __loc__start__pos
                      __loc__end__buf __loc__end__pos in
                  let ctp = id_loc ctp _loc_ctp in
                  pcty_loc _loc (Pcty_constr (ctp, tes)))])
    let class_type =
      Decap.sequence_position
        (locate
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l)
                    (Decap.fsequence
                       (Decap.option None
                          (Decap.apply (fun x  -> Some x) maybe_opt_label))
                       (Decap.sequence (Decap.string ":" ":") typexpr
                          (fun _  te  l  -> (l, te)))))))) class_body_type
        (fun tes  ->
           let (_loc_tes,tes) = tes in
           fun cbt  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             let app acc (lab,te) =
               match lab with
               | None  -> pcty_loc _loc (Pcty_fun ("", te, acc))
               | Some l ->
                   pcty_loc _loc
                     (Pcty_fun
                        (l,
                          (if (l.[0]) = '?' then mkoption _loc_tes te else te),
                          acc)) in
             List.fold_left app cbt (List.rev tes))
    let type_parameters =
      Decap.sequence type_param
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.sequence (Decap.string "," ",") type_param
                    (fun _  i2  -> i2))))) (fun i1  l  -> i1 :: l)
    let class_spec =
      Decap.fsequence_position virtual_flag
        (Decap.fsequence
           (locate
              (Decap.option []
                 (Decap.fsequence (Decap.string "[" "[")
                    (Decap.sequence type_parameters (Decap.string "]" "]")
                       (fun params  _  _  -> params)))))
           (Decap.fsequence (locate class_name)
              (Decap.sequence (Decap.string ":" ":") class_type
                 (fun _  ct  cn  ->
                    let (_loc_cn,cn) = cn in
                    fun params  ->
                      let (_loc_params,params) = params in
                      fun v  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        class_type_declaration _loc_params _loc
                          (id_loc cn _loc_cn) params v ct))))
    let class_specification =
      Decap.sequence class_spec
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.sequence and_kw class_spec (fun _  cd  -> cd)))))
        (fun cs  css  -> cs :: css)
    let classtype_def =
      Decap.fsequence_position virtual_flag
        (Decap.fsequence
           (locate
              (Decap.option []
                 (Decap.fsequence (Decap.string "[" "[")
                    (Decap.sequence type_parameters (Decap.string "]" "]")
                       (fun tp  _  _  -> tp)))))
           (Decap.fsequence (locate class_name)
              (Decap.sequence (Decap.char '=' '=') class_body_type
                 (fun _  cbt  cn  ->
                    let (_loc_cn,cn) = cn in
                    fun params  ->
                      let (_loc_params,params) = params in
                      fun v  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        class_type_declaration _loc_params _loc
                          (id_loc cn _loc_cn) params v cbt))))
    let classtype_definition =
      Decap.fsequence type_kw
        (Decap.sequence classtype_def
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l)
                    (Decap.sequence and_kw classtype_def (fun _  cd  -> cd)))))
           (fun cd  cds  _  -> cd :: cds))
    let constant =
      Decap.alternatives'
        [Decap.apply (fun f  -> Const_float f) float_literal;
        Decap.apply (fun c  -> Const_char c) char_literal;
        Decap.apply (fun s  -> const_string s) string_literal;
        Decap.apply (fun i  -> Const_int32 i) int32_lit;
        Decap.apply (fun i  -> Const_int64 i) int64_lit;
        Decap.apply (fun i  -> Const_nativeint i) nat_int_lit;
        Decap.apply (fun i  -> Const_int i) integer_literal]
    let neg_constant =
      Decap.alternatives'
        [Decap.sequence
           (Decap.alternatives'
              [Decap.apply (fun _  -> ()) (Decap.char '-' '-');
              Decap.apply (fun _  -> ()) (Decap.string "-." "-.")])
           float_literal (fun _  f  -> Const_float ("-" ^ f));
        Decap.sequence (Decap.char '-' '-') int32_lit
          (fun _  i  -> Const_int32 (Int32.neg i));
        Decap.sequence (Decap.char '-' '-') int64_lit
          (fun _  i  -> Const_int64 (Int64.neg i));
        Decap.sequence (Decap.char '-' '-') nat_int_lit
          (fun _  i  -> Const_nativeint (Nativeint.neg i));
        Decap.sequence (Decap.char '-' '-') integer_literal
          (fun _  i  -> Const_int (- i))]
    let pattern_prios =
      [TopPat; AsPat; AltPat; TupPat; ConsPat; ConstrPat; AtomPat]
    let next_pat_prio =
      function
      | TopPat  -> AsPat
      | AsPat  -> AltPat
      | AltPat  -> TupPat
      | TupPat  -> ConsPat
      | ConsPat  -> ConstrPat
      | ConstrPat  -> AtomPat
      | AtomPat  -> AtomPat
    let ppat_list _loc l =
      let nil = id_loc (Lident "[]") _loc in
      let cons x xs =
        let c = id_loc (Lident "::") _loc in
        let cons =
          ppat_construct (c, (Some (loc_pat _loc (Ppat_tuple [x; xs])))) in
        loc_pat _loc cons in
      List.fold_right cons l (loc_pat _loc (ppat_construct (nil, None)))
    let pattern_base =
      memoize1
        (fun lvl  ->
           Decap.alternatives'
             ((Decap.apply (fun e  -> e) (alternatives extra_patterns)) ::
             (Decap.apply_position
                (fun vn  ->
                   let (_loc_vn,vn) = vn in
                   fun __loc__start__buf  __loc__start__pos  __loc__end__buf 
                     __loc__end__pos  ->
                     let _loc =
                       locate2 __loc__start__buf __loc__start__pos
                         __loc__end__buf __loc__end__pos in
                     (AtomPat, (loc_pat _loc (Ppat_var (id_loc vn _loc_vn)))))
                (locate value_name)) ::
             (Decap.apply_position
                (fun _  __loc__start__buf  __loc__start__pos  __loc__end__buf
                    __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   (AtomPat, (loc_pat _loc Ppat_any))) (Decap.string "_" "_"))
             ::
             (Decap.fsequence_position char_literal
                (Decap.sequence (Decap.string ".." "..") char_literal
                   (fun _  c2  c1  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      let (ic1,ic2) = ((Char.code c1), (Char.code c2)) in
                      if ic1 > ic2 then assert false;
                      (let const i = Ppat_constant (Const_char (Char.chr i)) in
                       let rec range acc a b =
                         if a > b
                         then assert false
                         else
                           if a = b
                           then a :: acc
                           else range (a :: acc) (a + 1) b in
                       let opts =
                         List.map (fun i  -> loc_pat _loc (const i))
                           (range [] ic1 ic2) in
                       (AtomPat,
                         (List.fold_left
                            (fun acc  o  -> loc_pat _loc (Ppat_or (o, acc)))
                            (List.hd opts) (List.tl opts))))))) ::
             (Decap.apply_position
                (fun c  __loc__start__buf  __loc__start__pos  __loc__end__buf
                    __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   (AtomPat, (loc_pat _loc (Ppat_constant c))))
                (Decap.alternatives'
                   [Decap.apply (fun c  -> c) constant;
                   Decap.apply (fun c  -> c) neg_constant])) ::
             (Decap.fsequence (Decap.string "(" "(")
                (Decap.sequence pattern (Decap.string ")" ")")
                   (fun p  _  _  -> (AtomPat, p)))) ::
             (let y =
                let y =
                  (Decap.apply_position
                     (fun c  ->
                        let (_loc_c,c) = c in
                        fun __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          let ast = ppat_construct ((id_loc c _loc_c), None) in
                          (AtomPat, (loc_pat _loc ast))) (locate constr))
                  ::
                  (Decap.apply_position
                     (fun b  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let fls = id_loc (Lident b) _loc in
                        (AtomPat,
                          (loc_pat _loc (ppat_construct (fls, None)))))
                     bool_lit)
                  ::
                  (let y =
                     [Decap.apply_position
                        (fun c  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           (AtomPat, (loc_pat _loc (Ppat_variant (c, None)))))
                        tag_name;
                     Decap.sequence_position (Decap.string "#" "#")
                       (locate typeconstr)
                       (fun s  t  ->
                          let (_loc_t,t) = t in
                          fun __loc__start__buf  __loc__start__pos 
                            __loc__end__buf  __loc__end__pos  ->
                            let _loc =
                              locate2 __loc__start__buf __loc__start__pos
                                __loc__end__buf __loc__end__pos in
                            (AtomPat,
                              (loc_pat _loc (Ppat_type (id_loc t _loc_t)))));
                     Decap.fsequence_position (Decap.string "{" "{")
                       (Decap.fsequence (locate field)
                          (Decap.fsequence
                             (Decap.option None
                                (Decap.apply (fun x  -> Some x)
                                   (Decap.sequence (Decap.char '=' '=')
                                      pattern (fun _  p  -> p))))
                             (Decap.fsequence
                                (Decap.apply List.rev
                                   (Decap.fixpoint []
                                      (Decap.apply (fun x  l  -> x :: l)
                                         (Decap.fsequence
                                            (Decap.string ";" ";")
                                            (Decap.sequence (locate field)
                                               (Decap.option None
                                                  (Decap.apply
                                                     (fun x  -> Some x)
                                                     (Decap.sequence
                                                        (Decap.char '=' '=')
                                                        pattern
                                                        (fun _  p  -> p))))
                                               (fun f  ->
                                                  let (_loc_f,f) = f in
                                                  fun p  _  ->
                                                    ((id_loc f _loc_f), p)))))))
                                (Decap.fsequence
                                   (Decap.option None
                                      (Decap.apply (fun x  -> Some x)
                                         (Decap.sequence
                                            (Decap.string ";" ";")
                                            (Decap.string "_" "_")
                                            (fun _  _  -> ()))))
                                   (Decap.sequence
                                      (Decap.option None
                                         (Decap.apply (fun x  -> Some x)
                                            (Decap.string ";" ";")))
                                      (Decap.string "}" "}")
                                      (fun _  _  clsd  fps  p  f  ->
                                         let (_loc_f,f) = f in
                                         fun s  __loc__start__buf 
                                           __loc__start__pos  __loc__end__buf
                                            __loc__end__pos  ->
                                           let _loc =
                                             locate2 __loc__start__buf
                                               __loc__start__pos
                                               __loc__end__buf
                                               __loc__end__pos in
                                           let all = ((id_loc f _loc_f), p)
                                             :: fps in
                                           let f (lab,pat) =
                                             match pat with
                                             | Some p -> (lab, p)
                                             | None  ->
                                                 let slab =
                                                   match lab.txt with
                                                   | Lident s ->
                                                       id_loc s lab.loc
                                                   | _ -> raise Give_up in
                                                 (lab,
                                                   (loc_pat lab.loc
                                                      (Ppat_var slab))) in
                                           let all = List.map f all in
                                           let cl =
                                             match clsd with
                                             | None  -> Closed
                                             | Some _ -> Open in
                                           (AtomPat,
                                             (loc_pat _loc
                                                (Ppat_record (all, cl))))))))));
                     Decap.fsequence_position (Decap.string "[" "[")
                       (Decap.fsequence pattern
                          (Decap.fsequence
                             (Decap.apply List.rev
                                (Decap.fixpoint []
                                   (Decap.apply (fun x  l  -> x :: l)
                                      (Decap.sequence (Decap.string ";" ";")
                                         pattern (fun _  p  -> p)))))
                             (Decap.sequence
                                (Decap.option None
                                   (Decap.apply (fun x  -> Some x)
                                      (Decap.string ";" ";")))
                                (Decap.string "]" "]")
                                (fun _  _  ps  p  _  __loc__start__buf 
                                   __loc__start__pos  __loc__end__buf 
                                   __loc__end__pos  ->
                                   let _loc =
                                     locate2 __loc__start__buf
                                       __loc__start__pos __loc__end__buf
                                       __loc__end__pos in
                                   (AtomPat, (ppat_list _loc (p :: ps)))))));
                     Decap.sequence_position (Decap.string "[" "[")
                       (Decap.string "]" "]")
                       (fun _  _  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          let nil = id_loc (Lident "[]") _loc in
                          (AtomPat,
                            (loc_pat _loc (ppat_construct (nil, None)))));
                     Decap.fsequence_position (Decap.string "[|" "[|")
                       (Decap.fsequence pattern
                          (Decap.fsequence
                             (Decap.apply List.rev
                                (Decap.fixpoint []
                                   (Decap.apply (fun x  l  -> x :: l)
                                      (Decap.sequence (Decap.string ";" ";")
                                         pattern (fun _  p  -> p)))))
                             (Decap.sequence
                                (Decap.option None
                                   (Decap.apply (fun x  -> Some x)
                                      (Decap.string ";" ";")))
                                (Decap.string "|]" "|]")
                                (fun _  _  ps  p  _  __loc__start__buf 
                                   __loc__start__pos  __loc__end__buf 
                                   __loc__end__pos  ->
                                   let _loc =
                                     locate2 __loc__start__buf
                                       __loc__start__pos __loc__end__buf
                                       __loc__end__pos in
                                   (AtomPat,
                                     (loc_pat _loc (Ppat_array (p :: ps))))))));
                     Decap.sequence_position (Decap.string "[|" "[|")
                       (Decap.string "|]" "|]")
                       (fun _  _  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          (AtomPat, (loc_pat _loc (Ppat_array []))));
                     Decap.sequence_position (Decap.string "(" "(")
                       (Decap.string ")" ")")
                       (fun _  _  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          let unt = id_loc (Lident "()") _loc in
                          (AtomPat,
                            (loc_pat _loc (ppat_construct (unt, None)))));
                     Decap.sequence_position begin_kw end_kw
                       (fun _  _  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          let unt = id_loc (Lident "()") _loc in
                          (AtomPat,
                            (loc_pat _loc (ppat_construct (unt, None)))));
                     Decap.fsequence_position (Decap.string "(" "(")
                       (Decap.fsequence module_kw
                          (Decap.fsequence (locate module_name)
                             (Decap.sequence
                                (locate
                                   (Decap.option None
                                      (Decap.apply (fun x  -> Some x)
                                         (Decap.sequence
                                            (Decap.string ":" ":")
                                            package_type (fun _  pt  -> pt)))))
                                (Decap.string ")" ")")
                                (fun pt  ->
                                   let (_loc_pt,pt) = pt in
                                   fun _  mn  ->
                                     let (_loc_mn,mn) = mn in
                                     fun _  _  __loc__start__buf 
                                       __loc__start__pos  __loc__end__buf 
                                       __loc__end__pos  ->
                                       let _loc =
                                         locate2 __loc__start__buf
                                           __loc__start__pos __loc__end__buf
                                           __loc__end__pos in
                                       let unpack =
                                         Ppat_unpack
                                           { txt = mn; loc = _loc_mn } in
                                       let pat =
                                         match pt with
                                         | None  -> unpack
                                         | Some pt ->
                                             let pt = loc_typ _loc_pt pt in
                                             Ppat_constraint
                                               ((loc_pat _loc_mn unpack), pt) in
                                       (AtomPat, (loc_pat _loc pat))))));
                     Decap.sequence (Decap.char '$' '$') capitalized_ident
                       (fun _  c  ->
                          try
                            let str = Sys.getenv c in
                            (AtomPat,
                              (parse_string ~filename:("ENV:" ^ c) pattern
                                 blank str))
                          with | Not_found  -> raise Give_up);
                     Decap.fsequence_position (Decap.char '$' '$')
                       (Decap.fsequence
                          (Decap.option None
                             (Decap.apply (fun x  -> Some x)
                                (Decap.sequence
                                   (Decap.alternatives'
                                      [Decap.apply (fun _  -> "tuple")
                                         (Decap.string "tuple" "tuple");
                                      Decap.apply (fun _  -> "list")
                                        (Decap.string "list" "list");
                                      Decap.apply (fun _  -> "array")
                                        (Decap.string "array" "array")])
                                   (Decap.char ':' ':') (fun t  _  -> t))))
                          (Decap.sequence (expression_lvl (next_exp App))
                             (Decap.char '$' '$')
                             (fun e  _  t  _  __loc__start__buf 
                                __loc__start__pos  __loc__end__buf 
                                __loc__end__pos  ->
                                let _loc =
                                  locate2 __loc__start__buf __loc__start__pos
                                    __loc__end__buf __loc__end__pos in
                                match t with
                                | None  -> (AtomPat, (push_pop_pattern e))
                                | Some str ->
                                    let l = push_pop_pattern_list e in
                                    (match str with
                                     | "tuple" ->
                                         (AtomPat,
                                           (loc_pat _loc (Ppat_tuple l)))
                                     | "array" ->
                                         (AtomPat,
                                           (loc_pat _loc (Ppat_array l)))
                                     | "list" ->
                                         (AtomPat, (ppat_list _loc l))
                                     | _ -> raise Give_up))))] in
                   if lvl <= ConstrPat
                   then
                     (Decap.sequence_position tag_name
                        (pattern_lvl ConstrPat)
                        (fun c  p  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           (ConstrPat,
                             (loc_pat _loc (Ppat_variant (c, (Some p)))))))
                     :: y
                   else y) in
                if lvl <= ConstrPat
                then
                  (Decap.sequence_position (locate constr)
                     (pattern_lvl ConstrPat)
                     (fun c  ->
                        let (_loc_c,c) = c in
                        fun p  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          let ast =
                            ppat_construct ((id_loc c _loc_c), (Some p)) in
                          (ConstrPat, (loc_pat _loc ast))))
                  :: y
                else y in
              if lvl <= ConstrPat
              then
                (Decap.sequence_position lazy_kw (pattern_lvl ConstrPat)
                   (fun _  p  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      let ast = Ppat_lazy p in
                      (ConstrPat, (loc_pat _loc ast))))
                :: y
              else y)))
    let pattern_suit_aux:
      pattern_prio ->
        pattern_prio -> (pattern_prio* (pattern -> pattern)) grammar
      =
      memoize1
        (fun lvl'  lvl  ->
           let ln f _loc e = loc_pat (merge2 f.ppat_loc _loc) e in
           Decap.alternatives'
             (let y =
                let y =
                  let y =
                    let y =
                      let y =
                        let y = [] in
                        if (lvl' >= TopPat) && (lvl <= TopPat)
                        then
                          (Decap.sequence_position (Decap.string ":" ":")
                             typexpr
                             (fun _  ty  __loc__start__buf  __loc__start__pos
                                 __loc__end__buf  __loc__end__pos  ->
                                let _loc =
                                  locate2 __loc__start__buf __loc__start__pos
                                    __loc__end__buf __loc__end__pos in
                                (lvl',
                                  (fun p  ->
                                     ln p _loc (Ppat_constraint (p, ty))))))
                          :: y
                        else y in
                      if (lvl' >= AsPat) && (lvl <= AsPat)
                      then
                        (Decap.fsequence_position (Decap.string ":" ":")
                           (Decap.fsequence
                              (Decap.sequence
                                 (Decap.sequence (Decap.string "'" "'") ident
                                    (fun _  id  -> id))
                                 (Decap.fixpoint []
                                    (Decap.apply (fun x  l  -> x :: l)
                                       (Decap.sequence (Decap.string "'" "'")
                                          ident (fun _  id  -> id))))
                                 (fun x  l  -> x :: (List.rev l)))
                              (Decap.sequence (Decap.string "." ".") typexpr
                                 (fun _  te  ids  _  __loc__start__buf 
                                    __loc__start__pos  __loc__end__buf 
                                    __loc__end__pos  ->
                                    let _loc =
                                      locate2 __loc__start__buf
                                        __loc__start__pos __loc__end__buf
                                        __loc__end__pos in
                                    (AsPat,
                                      (fun p  ->
                                         ln p _loc
                                           (Ppat_constraint
                                              (p,
                                                (loc_typ _loc
                                                   (Ptyp_poly (ids, te)))))))))))
                        :: y
                      else y in
                    if (lvl' > ConsPat) && (lvl <= ConsPat)
                    then
                      (Decap.sequence_position
                         (locate (Decap.string "::" "::"))
                         (pattern_lvl ConsPat)
                         (fun c  ->
                            let (_loc_c,c) = c in
                            fun p'  __loc__start__buf  __loc__start__pos 
                              __loc__end__buf  __loc__end__pos  ->
                              let _loc =
                                locate2 __loc__start__buf __loc__start__pos
                                  __loc__end__buf __loc__end__pos in
                              (ConsPat,
                                (fun p  ->
                                   let cons = id_loc (Lident "::") _loc_c in
                                   let args =
                                     loc_pat _loc (Ppat_tuple [p; p']) in
                                   ln p _loc
                                     (ppat_construct (cons, (Some args)))))))
                      :: y
                    else y in
                  if (lvl' > TupPat) && (lvl <= TupPat)
                  then
                    (Decap.apply_position
                       (fun ps  __loc__start__buf  __loc__start__pos 
                          __loc__end__buf  __loc__end__pos  ->
                          let _loc =
                            locate2 __loc__start__buf __loc__start__pos
                              __loc__end__buf __loc__end__pos in
                          (TupPat,
                            (fun p  -> ln p _loc (Ppat_tuple (p :: ps)))))
                       (Decap.sequence
                          (Decap.sequence (Decap.string "," ",")
                             (pattern_lvl (next_pat_prio TupPat))
                             (fun _  p  -> p))
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                (Decap.sequence (Decap.string "," ",")
                                   (pattern_lvl (next_pat_prio TupPat))
                                   (fun _  p  -> p))))
                          (fun x  l  -> x :: (List.rev l))))
                    :: y
                  else y in
                if (lvl' >= AltPat) && (lvl <= AltPat)
                then
                  (Decap.sequence_position (Decap.string "|" "|")
                     (pattern_lvl (next_pat_prio AltPat))
                     (fun _  p'  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        (AltPat, (fun p  -> ln p _loc (Ppat_or (p, p'))))))
                  :: y
                else y in
              if (lvl' >= AsPat) && (lvl <= AsPat)
              then
                (Decap.sequence_position as_kw (locate value_name)
                   (fun _  vn  ->
                      let (_loc_vn,vn) = vn in
                      fun __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        (lvl',
                          (fun p  ->
                             ln p _loc (Ppat_alias (p, (id_loc vn _loc_vn)))))))
                :: y
              else y))
    let pattern_suit =
      let f =
        memoize2'
          (fun pat_suit  lvl'  lvl  ->
             Decap.alternatives'
               [Decap.iter
                  (Decap.apply
                     (fun (p1,f1)  ->
                        Decap.apply
                          (fun (p2,f2)  -> (p2, (fun f  -> f2 (f1 f))))
                          (pat_suit p1 lvl)) (pattern_suit_aux lvl' lvl));
               Decap.apply (fun _  -> (lvl', (fun f  -> f))) (Decap.empty ())]) in
      let rec res x y = f res x y in res
    let _ =
      set_pattern_lvl
        (fun lvl  ->
           Decap.iter
             (Decap.apply
                (fun (lvl',t)  ->
                   Decap.apply (fun ft  -> snd ft t) (pattern_suit lvl' lvl))
                (pattern_base lvl)))
    let expression_lvls =
      [Top;
      Let;
      Seq;
      Coerce;
      If;
      Aff;
      Tupl;
      Disj;
      Conj;
      Eq;
      Append;
      Cons;
      Sum;
      Prod;
      Pow;
      Opp;
      App;
      Dash;
      Dot;
      Prefix;
      Atom]
    let let_prio lvl = if !modern then lvl else Let
    let let_re = if !modern then "\\(let\\)\\|\\(val\\)\\b" else "let\\b"
    type assoc =  
      | NoAssoc
      | Left
      | Right 
    let assoc =
      function
      | Prefix |Dot |Dash |Opp  -> NoAssoc
      | Prod |Sum |Eq  -> Left
      | _ -> Right
    let infix_prio s =
      let s1 = if (String.length s) > 1 then s.[1] else ' ' in
      match ((s.[0]), s1) with
      | _ when List.mem s ["lsl"; "lsr"; "asr"] -> Pow
      | _ when List.mem s ["mod"; "land"; "lor"; "lxor"] -> Prod
      | _ when List.mem s ["&"; "&&"] -> Conj
      | _ when List.mem s ["or"; "||"] -> Disj
      | _ when List.mem s [":="; "<-"] -> Aff
      | ('*','*') -> Pow
      | (('*'|'/'|'%'),_) -> Prod
      | (('+'|'-'),_) -> Sum
      | (':',_) -> Cons
      | (('@'|'^'),_) -> Append
      | (('='|'<'|'>'|'|'|'&'|'$'|'!'),_) -> Eq
      | _ -> (Printf.printf "%s\n%!" s; assert false)
    let prefix_prio s =
      if (s = "-") || ((s = "-.") || ((s = "+") || (s = "+.")))
      then Opp
      else Prefix
    let array_function loc str name =
      let name = if !fast then "unsafe_" ^ name else name in
      loc_expr loc (Pexp_ident (id_loc (Ldot ((Lident str), name)) loc))
    let bigarray_function loc str name =
      let name = if !fast then "unsafe_" ^ name else name in
      let lid = Ldot ((Ldot ((Lident "Bigarray"), str)), name) in
      loc_expr loc (Pexp_ident (id_loc lid loc))
    let untuplify exp =
      match exp.pexp_desc with | Pexp_tuple es -> es | _ -> [exp]
    let bigarray_get loc arr arg =
      let get = if !fast then "unsafe_get" else "get" in
      match untuplify arg with
      | c1::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array1" get), [("", arr); ("", c1)]))
      | c1::c2::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array2" get),
                 [("", arr); ("", c1); ("", c2)]))
      | c1::c2::c3::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array3" get),
                 [("", arr); ("", c1); ("", c2); ("", c3)]))
      | coords ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Genarray" "get"),
                 [("", arr); ("", (loc_expr loc (Pexp_array coords)))]))
    let bigarray_set loc arr arg newval =
      let set = if !fast then "unsafe_set" else "set" in
      match untuplify arg with
      | c1::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array1" set),
                 [("", arr); ("", c1); ("", newval)]))
      | c1::c2::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array2" set),
                 [("", arr); ("", c1); ("", c2); ("", newval)]))
      | c1::c2::c3::[] ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Array3" set),
                 [("", arr); ("", c1); ("", c2); ("", c3); ("", newval)]))
      | coords ->
          loc_expr loc
            (Pexp_apply
               ((bigarray_function loc "Genarray" "set"),
                 [("", arr);
                 ("", (loc_expr loc (Pexp_array coords)));
                 ("", newval)]))
    let constructor =
      Decap.sequence
        (Decap.option None
           (Decap.apply (fun x  -> Some x)
              (Decap.sequence module_path (Decap.string "." ".")
                 (fun m  _  -> m))))
        (Decap.alternatives'
           [Decap.apply (fun id  -> id) capitalized_ident;
           Decap.apply (fun b  -> b) bool_lit])
        (fun m  id  ->
           match m with | None  -> Lident id | Some m -> Ldot (m, id))
    let argument =
      Decap.alternatives'
        [Decap.fsequence label
           (Decap.sequence (Decap.string ":" ":")
              (expression_lvl (next_exp App)) (fun _  e  id  -> (id, e)));
        Decap.fsequence opt_label
          (Decap.sequence (Decap.string ":" ":")
             (expression_lvl (next_exp App))
             (fun _  e  id  -> (("?" ^ id), e)));
        Decap.apply_position
          (fun id  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             (id, (loc_expr _loc (Pexp_ident (id_loc (Lident id) _loc)))))
          label;
        Decap.apply_position
          (fun id  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             (("?" ^ id),
               (loc_expr _loc (Pexp_ident (id_loc (Lident id) _loc)))))
          opt_label;
        Decap.apply (fun e  -> ("", e)) (expression_lvl (next_exp App))]
    let parameter allow_new_type =
      Decap.alternatives'
        ((Decap.apply (fun pat  -> `Arg ("", None, pat))
            (pattern_lvl AtomPat)) ::
        (Decap.fsequence_position (Decap.string "~" "~")
           (Decap.fsequence (Decap.string "(" "(")
              (Decap.fsequence (locate lowercase_ident)
                 (Decap.sequence
                    (Decap.option None
                       (Decap.apply (fun x  -> Some x)
                          (Decap.sequence (Decap.string ":" ":") typexpr
                             (fun _  t  -> t)))) (Decap.string ")" ")")
                    (fun t  _  id  ->
                       let (_loc_id,id) = id in
                       fun _  _  __loc__start__buf  __loc__start__pos 
                         __loc__end__buf  __loc__end__pos  ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         let pat =
                           loc_pat _loc_id (Ppat_var (id_loc id _loc_id)) in
                         let pat =
                           match t with
                           | None  -> pat
                           | Some t ->
                               loc_pat _loc (Ppat_constraint (pat, t)) in
                         `Arg (id, None, pat)))))) ::
        (Decap.fsequence label
           (Decap.sequence (Decap.string ":" ":") pattern
              (fun _  pat  id  -> `Arg (id, None, pat)))) ::
        (Decap.sequence (Decap.char '~' '~') (locate ident)
           (fun _  id  ->
              let (_loc_id,id) = id in
              `Arg
                (id, None, (loc_pat _loc_id (Ppat_var (id_loc id _loc_id))))))
        ::
        (Decap.fsequence (Decap.string "?" "?")
           (Decap.fsequence (Decap.string "(" "(")
              (Decap.fsequence (locate lowercase_ident)
                 (Decap.fsequence
                    (locate
                       (Decap.option None
                          (Decap.apply (fun x  -> Some x)
                             (Decap.sequence (Decap.string ":" ":") typexpr
                                (fun _  t  -> t)))))
                    (Decap.sequence
                       (Decap.option None
                          (Decap.apply (fun x  -> Some x)
                             (Decap.sequence (Decap.string "=" "=")
                                expression (fun _  e  -> e))))
                       (Decap.string ")" ")")
                       (fun e  _  t  ->
                          let (_loc_t,t) = t in
                          fun id  ->
                            let (_loc_id,id) = id in
                            fun _  _  ->
                              let pat =
                                loc_pat _loc_id
                                  (Ppat_var (id_loc id _loc_id)) in
                              let pat =
                                match t with
                                | None  -> pat
                                | Some t ->
                                    loc_pat (merge2 _loc_id _loc_t)
                                      (Ppat_constraint (pat, t)) in
                              `Arg (("?" ^ id), e, pat))))))) ::
        (Decap.fsequence opt_label
           (Decap.fsequence (Decap.string ":" ":")
              (Decap.fsequence (Decap.string "(" "(")
                 (Decap.fsequence (locate pattern)
                    (Decap.fsequence
                       (locate
                          (Decap.option None
                             (Decap.apply (fun x  -> Some x)
                                (Decap.sequence (Decap.string ":" ":")
                                   typexpr (fun _  t  -> t)))))
                       (Decap.sequence
                          (Decap.option None
                             (Decap.apply (fun x  -> Some x)
                                (Decap.sequence (Decap.char '=' '=')
                                   expression (fun _  e  -> e))))
                          (Decap.string ")" ")")
                          (fun e  _  t  ->
                             let (_loc_t,t) = t in
                             fun pat  ->
                               let (_loc_pat,pat) = pat in
                               fun _  _  id  ->
                                 let pat =
                                   match t with
                                   | None  -> pat
                                   | Some t ->
                                       loc_pat (merge2 _loc_pat _loc_t)
                                         (Ppat_constraint (pat, t)) in
                                 `Arg (("?" ^ id), e, pat)))))))) ::
        (Decap.fsequence opt_label
           (Decap.sequence (Decap.string ":" ":") pattern
              (fun _  pat  id  -> `Arg (("?" ^ id), None, pat)))) ::
        (Decap.apply
           (fun id  ->
              let (_loc_id,id) = id in
              `Arg
                (("?" ^ id), None,
                  (loc_pat _loc_id (Ppat_var (id_loc id _loc_id)))))
           (locate opt_label)) ::
        (let y = [] in
         if allow_new_type
         then
           (Decap.fsequence (Decap.char '(' '(')
              (Decap.fsequence type_kw
                 (Decap.sequence typeconstr_name (Decap.char ')' ')')
                    (fun name  _  _  _  -> `Type name))))
           :: y
         else y))
    let apply_params params e =
      let f acc =
        function
        | (`Arg (lbl,opt,pat),_loc') ->
            loc_expr (merge2 _loc' e.pexp_loc)
              (pexp_fun (lbl, opt, pat, acc))
        | (`Type name,_loc') ->
            loc_expr (merge2 _loc' e.pexp_loc) (Pexp_newtype (name, acc)) in
      List.fold_left f e (List.rev params)
    let apply_params_cls _loc params e =
      let f acc =
        function
        | `Arg (lbl,opt,pat) -> loc_pcl _loc (Pcl_fun (lbl, opt, pat, acc))
        | `Type name -> assert false in
      List.fold_left f e (List.rev params)
    let right_member =
      Decap.fsequence_position
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.apply
                    (fun lb  -> let (_loc_lb,lb) = lb in (lb, _loc_lb))
                    (locate (parameter true))))))
        (Decap.fsequence
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.sequence (Decap.char ':' ':') typexpr
                    (fun _  t  -> t))))
           (Decap.sequence (Decap.char '=' '=') expression
              (fun _  e  ty  l  __loc__start__buf  __loc__start__pos 
                 __loc__end__buf  __loc__end__pos  ->
                 let _loc =
                   locate2 __loc__start__buf __loc__start__pos
                     __loc__end__buf __loc__end__pos in
                 let e =
                   match ty with
                   | None  -> e
                   | Some ty -> loc_expr _loc (pexp_constraint (e, ty)) in
                 apply_params l e)))
    let _ =
      set_grammar let_binding
        (Decap.alternatives'
           [Decap.fsequence (locate (pattern_lvl AsPat))
              (Decap.fsequence (locate right_member)
                 (Decap.sequence post_item_attributes
                    (Decap.option []
                       (Decap.sequence and_kw let_binding (fun _  l  -> l)))
                    (fun a  l  e  ->
                       let (_loc_e,e) = e in
                       fun pat  ->
                         let (_loc_pat,pat) = pat in
                         (value_binding ~attributes:a
                            (merge2 _loc_pat _loc_e) pat e)
                           :: l)));
           Decap.fsequence_position (locate lowercase_ident)
             (Decap.fsequence (Decap.char ':' ':')
                (Decap.fsequence poly_typexpr
                   (Decap.fsequence (locate right_member)
                      (Decap.sequence post_item_attributes
                         (Decap.option []
                            (Decap.sequence and_kw let_binding
                               (fun _  l  -> l)))
                         (fun a  l  e  ->
                            let (_loc_e,e) = e in
                            fun ty  _  vn  ->
                              let (_loc_vn,vn) = vn in
                              fun __loc__start__buf  __loc__start__pos 
                                __loc__end__buf  __loc__end__pos  ->
                                let _loc =
                                  locate2 __loc__start__buf __loc__start__pos
                                    __loc__end__buf __loc__end__pos in
                                let pat =
                                  loc_pat _loc
                                    (Ppat_constraint
                                       ((loc_pat _loc
                                           (Ppat_var (id_loc vn _loc_vn))),
                                         ty)) in
                                (value_binding ~attributes:a
                                   (merge2 _loc_vn _loc_e) pat e)
                                  :: l)))));
           Decap.fsequence_position (locate lowercase_ident)
             (Decap.fsequence (Decap.char ':' ':')
                (Decap.fsequence poly_syntax_typexpr
                   (Decap.fsequence (locate right_member)
                      (Decap.sequence post_item_attributes
                         (Decap.option []
                            (Decap.sequence and_kw let_binding
                               (fun _  l  -> l)))
                         (fun a  l  e  ->
                            let (_loc_e,e) = e in
                            fun (ids,ty)  _  vn  ->
                              let (_loc_vn,vn) = vn in
                              fun __loc__start__buf  __loc__start__pos 
                                __loc__end__buf  __loc__end__pos  ->
                                let _loc =
                                  locate2 __loc__start__buf __loc__start__pos
                                    __loc__end__buf __loc__end__pos in
                                let (e,ty) =
                                  wrap_type_annotation _loc ids ty e in
                                let pat =
                                  loc_pat _loc
                                    (Ppat_constraint
                                       ((loc_pat _loc
                                           (Ppat_var (id_loc vn _loc_vn))),
                                         ty)) in
                                (value_binding ~attributes:a
                                   (merge2 _loc_vn _loc_e) pat e)
                                  :: l)))))])
    let match_cases =
      memoize1
        (fun lvl  ->
           Decap.apply (fun l  -> l)
             (Decap.option []
                (Decap.fsequence
                   (Decap.option None
                      (Decap.apply (fun x  -> Some x) (Decap.string "|" "|")))
                   (Decap.fsequence pattern
                      (Decap.fsequence
                         (Decap.option None
                            (Decap.apply (fun x  -> Some x)
                               (Decap.sequence when_kw expression
                                  (fun _  e  -> e))))
                         (Decap.fsequence (Decap.string "->" "->")
                            (Decap.sequence (expression_lvl lvl)
                               (Decap.apply List.rev
                                  (Decap.fixpoint []
                                     (Decap.apply (fun x  l  -> x :: l)
                                        (Decap.fsequence
                                           (Decap.string "|" "|")
                                           (Decap.fsequence pattern
                                              (Decap.fsequence
                                                 (Decap.option None
                                                    (Decap.apply
                                                       (fun x  -> Some x)
                                                       (Decap.sequence
                                                          when_kw expression
                                                          (fun _  e  -> e))))
                                                 (Decap.sequence
                                                    (Decap.string "->" "->")
                                                    (expression_lvl lvl)
                                                    (fun _  e  w  pat  _  ->
                                                       (pat, e, w)))))))))
                               (fun e  l  _  w  pat  _  ->
                                  map_cases ((pat, e, w) :: l)))))))))
    let type_coercion =
      Decap.alternatives'
        [Decap.fsequence (Decap.string ":" ":")
           (Decap.sequence typexpr
              (Decap.option None
                 (Decap.apply (fun x  -> Some x)
                    (Decap.sequence (Decap.string ":>" ":>") typexpr
                       (fun _  t'  -> t'))))
              (fun t  t'  _  -> ((Some t), t')));
        Decap.sequence (Decap.string ":>" ":>") typexpr
          (fun _  t'  -> (None, (Some t')))]
    let expression_list =
      Decap.alternatives'
        [Decap.fsequence (locate (expression_lvl (next_exp Seq)))
           (Decap.sequence
              (Decap.apply List.rev
                 (Decap.fixpoint []
                    (Decap.apply (fun x  l  -> x :: l)
                       (Decap.sequence (Decap.string ";" ";")
                          (locate (expression_lvl (next_exp Seq)))
                          (fun _  e  -> let (_loc_e,e) = e in (e, _loc_e))))))
              (Decap.option None
                 (Decap.apply (fun x  -> Some x) (Decap.string ";" ";")))
              (fun l  _  e  -> let (_loc_e,e) = e in (e, _loc_e) :: l));
        Decap.apply (fun _  -> []) (Decap.empty ())]
    let record_item =
      Decap.alternatives'
        [Decap.fsequence (locate field)
           (Decap.sequence (Decap.char '=' '=')
              (expression_lvl (next_exp Seq))
              (fun _  e  f  -> let (_loc_f,f) = f in ((id_loc f _loc_f), e)));
        Decap.apply
          (fun f  ->
             let (_loc_f,f) = f in
             let id = id_loc (Lident f) _loc_f in
             (id, (loc_expr _loc_f (Pexp_ident id))))
          (locate lowercase_ident)]
    let record_list =
      Decap.alternatives'
        [Decap.fsequence record_item
           (Decap.sequence
              (Decap.apply List.rev
                 (Decap.fixpoint []
                    (Decap.apply (fun x  l  -> x :: l)
                       (Decap.sequence (Decap.string ";" ";") record_item
                          (fun _  it  -> it)))))
              (Decap.option None
                 (Decap.apply (fun x  -> Some x) (Decap.string ";" ";")))
              (fun l  _  it  -> it :: l));
        Decap.apply (fun _  -> []) (Decap.empty ())]
    let obj_item =
      Decap.fsequence (locate inst_var_name)
        (Decap.sequence (Decap.char '=' '=') (expression_lvl (next_exp Seq))
           (fun _  e  v  -> let (_loc_v,v) = v in ((id_loc v _loc_v), e)))
    let class_expr_base =
      Decap.alternatives'
        [Decap.apply_position
           (fun cp  ->
              let (_loc_cp,cp) = cp in
              fun __loc__start__buf  __loc__start__pos  __loc__end__buf 
                __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                let cp = id_loc cp _loc_cp in
                loc_pcl _loc (Pcl_constr (cp, []))) (locate class_path);
        Decap.fsequence_position (Decap.char '[' '[')
          (Decap.fsequence typexpr
             (Decap.fsequence
                (Decap.apply List.rev
                   (Decap.fixpoint []
                      (Decap.apply (fun x  l  -> x :: l)
                         (Decap.sequence (Decap.string "," ",") typexpr
                            (fun _  te  -> te)))))
                (Decap.sequence (Decap.char ']' ']') (locate class_path)
                   (fun _  cp  ->
                      let (_loc_cp,cp) = cp in
                      fun tes  te  _  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let cp = id_loc cp _loc_cp in
                        loc_pcl _loc (Pcl_constr (cp, (te :: tes)))))));
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.sequence class_expr (Decap.string ")" ")")
             (fun ce  _  _  __loc__start__buf  __loc__start__pos 
                __loc__end__buf  __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                loc_pcl _loc ce.pcl_desc));
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence class_expr
             (Decap.fsequence (Decap.string ":" ":")
                (Decap.sequence class_type (Decap.string ")" ")")
                   (fun ct  _  _  ce  _  __loc__start__buf  __loc__start__pos
                       __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      loc_pcl _loc (Pcl_constraint (ce, ct))))));
        Decap.fsequence_position fun_kw
          (Decap.fsequence
             (Decap.sequence (parameter false)
                (Decap.fixpoint []
                   (Decap.apply (fun x  l  -> x :: l) (parameter false)))
                (fun x  l  -> x :: (List.rev l)))
             (Decap.sequence (Decap.string "->" "->") class_expr
                (fun _  ce  ps  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   apply_params_cls _loc ps ce)));
        Decap.fsequence_position let_kw
          (Decap.fsequence rec_flag
             (Decap.fsequence let_binding
                (Decap.sequence in_kw class_expr
                   (fun _  ce  lbs  r  _  __loc__start__buf 
                      __loc__start__pos  __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      loc_pcl _loc (Pcl_let (r, lbs, ce))))));
        Decap.fsequence_position object_kw
          (Decap.sequence class_body end_kw
             (fun cb  _  _  __loc__start__buf  __loc__start__pos 
                __loc__end__buf  __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                loc_pcl _loc (Pcl_structure cb)))]
    let _ =
      set_grammar class_expr
        (Decap.sequence_position class_expr_base
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.apply (fun arg  -> arg)
                    (Decap.sequence argument
                       (Decap.fixpoint []
                          (Decap.apply (fun x  l  -> x :: l) argument))
                       (fun x  l  -> x :: (List.rev l))))))
           (fun ce  args  __loc__start__buf  __loc__start__pos 
              __loc__end__buf  __loc__end__pos  ->
              let _loc =
                locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                  __loc__end__pos in
              match args with
              | None  -> ce
              | Some l -> loc_pcl _loc (Pcl_apply (ce, l))))
    let class_field =
      Decap.alternatives'
        [Decap.fsequence_position inherit_kw
           (Decap.fsequence override_flag
              (Decap.sequence class_expr
                 (Decap.option None
                    (Decap.apply (fun x  -> Some x)
                       (Decap.sequence as_kw lowercase_ident
                          (fun _  id  -> id))))
                 (fun ce  id  o  _  __loc__start__buf  __loc__start__pos 
                    __loc__end__buf  __loc__end__pos  ->
                    let _loc =
                      locate2 __loc__start__buf __loc__start__pos
                        __loc__end__buf __loc__end__pos in
                    loc_pcf _loc (Pcf_inher (o, ce, id)))));
        Decap.fsequence_position val_kw
          (Decap.fsequence override_flag
             (Decap.fsequence mutable_flag
                (Decap.fsequence (locate inst_var_name)
                   (Decap.fsequence
                      (locate
                         (Decap.option None
                            (Decap.apply (fun x  -> Some x)
                               (Decap.sequence (Decap.char ':' ':') typexpr
                                  (fun _  t  -> t)))))
                      (Decap.sequence (Decap.char '=' '=') expr
                         (fun _  e  te  ->
                            let (_loc_te,te) = te in
                            fun ivn  ->
                              let (_loc_ivn,ivn) = ivn in
                              fun m  o  _  __loc__start__buf 
                                __loc__start__pos  __loc__end__buf 
                                __loc__end__pos  ->
                                let _loc =
                                  locate2 __loc__start__buf __loc__start__pos
                                    __loc__end__buf __loc__end__pos in
                                let ivn = id_loc ivn _loc_ivn in
                                let ex =
                                  match te with
                                  | None  -> e
                                  | Some t ->
                                      loc_expr _loc_te
                                        (pexp_constraint (e, t)) in
                                loc_pcf _loc (Pcf_val (ivn, m, o, ex))))))));
        Decap.fsequence_position val_kw
          (Decap.fsequence mutable_flag
             (Decap.fsequence virtual_kw
                (Decap.fsequence (locate inst_var_name)
                   (Decap.sequence (Decap.string ":" ":") typexpr
                      (fun _  te  ivn  ->
                         let (_loc_ivn,ivn) = ivn in
                         fun _  m  _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let ivn = id_loc ivn _loc_ivn in
                           loc_pcf _loc (Pcf_valvirt (ivn, m, te)))))));
        Decap.fsequence_position val_kw
          (Decap.fsequence virtual_kw
             (Decap.fsequence mutable_kw
                (Decap.fsequence (locate inst_var_name)
                   (Decap.sequence (Decap.string ":" ":") typexpr
                      (fun _  te  ivn  ->
                         let (_loc_ivn,ivn) = ivn in
                         fun _  _  _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let ivn = id_loc ivn _loc_ivn in
                           loc_pcf _loc (Pcf_valvirt (ivn, Mutable, te)))))));
        Decap.fsequence_position method_kw
          (Decap.fsequence override_flag
             (Decap.fsequence private_flag
                (Decap.fsequence (locate method_name)
                   (Decap.fsequence (Decap.string ":" ":")
                      (Decap.fsequence poly_typexpr
                         (Decap.sequence (Decap.char '=' '=') expr
                            (fun _  e  te  _  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun p  o  _  __loc__start__buf 
                                 __loc__start__pos  __loc__end__buf 
                                 __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 let mn = id_loc mn _loc_mn in
                                 let e =
                                   loc_expr _loc (Pexp_poly (e, (Some te))) in
                                 loc_pcf _loc (Pcf_meth (mn, p, o, e)))))))));
        Decap.fsequence_position method_kw
          (Decap.fsequence override_flag
             (Decap.fsequence private_flag
                (Decap.fsequence (locate method_name)
                   (Decap.fsequence (Decap.string ":" ":")
                      (Decap.fsequence poly_syntax_typexpr
                         (Decap.sequence (Decap.char '=' '=') expr
                            (fun _  e  (ids,te)  _  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun p  o  _  __loc__start__buf 
                                 __loc__start__pos  __loc__end__buf 
                                 __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 let mn = id_loc mn _loc_mn in
                                 let (e,poly) =
                                   wrap_type_annotation _loc ids te e in
                                 let e =
                                   loc_expr _loc (Pexp_poly (e, (Some poly))) in
                                 loc_pcf _loc (Pcf_meth (mn, p, o, e)))))))));
        Decap.fsequence_position method_kw
          (Decap.fsequence override_flag
             (Decap.fsequence private_flag
                (Decap.fsequence (locate method_name)
                   (Decap.fsequence
                      (Decap.apply List.rev
                         (Decap.fixpoint []
                            (Decap.apply (fun x  l  -> x :: l)
                               (Decap.apply
                                  (fun p  ->
                                     let (_loc_p,p) = p in (p, _loc_p))
                                  (locate (parameter true))))))
                      (Decap.fsequence
                         (Decap.option None
                            (Decap.apply (fun x  -> Some x)
                               (Decap.sequence (Decap.string ":" ":") typexpr
                                  (fun _  te  -> te))))
                         (Decap.sequence (Decap.char '=' '=') expr
                            (fun _  e  te  ps  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun p  o  _  __loc__start__buf 
                                 __loc__start__pos  __loc__end__buf 
                                 __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 let mn = id_loc mn _loc_mn in
                                 let e =
                                   match te with
                                   | None  -> e
                                   | Some te ->
                                       loc_expr _loc
                                         (pexp_constraint (e, te)) in
                                 let e: expression = apply_params ps e in
                                 let e = loc_expr _loc (Pexp_poly (e, None)) in
                                 loc_pcf _loc (Pcf_meth (mn, p, o, e)))))))));
        Decap.fsequence_position method_kw
          (Decap.fsequence private_flag
             (Decap.fsequence virtual_kw
                (Decap.fsequence (locate method_name)
                   (Decap.sequence (Decap.string ":" ":") poly_typexpr
                      (fun _  pte  mn  ->
                         let (_loc_mn,mn) = mn in
                         fun _  p  _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let mn = id_loc mn _loc_mn in
                           loc_pcf _loc (Pcf_virt (mn, p, pte)))))));
        Decap.fsequence_position method_kw
          (Decap.fsequence virtual_kw
             (Decap.fsequence private_kw
                (Decap.fsequence (locate method_name)
                   (Decap.sequence (Decap.string ":" ":") poly_typexpr
                      (fun _  pte  mn  ->
                         let (_loc_mn,mn) = mn in
                         fun _  _  _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let mn = id_loc mn _loc_mn in
                           loc_pcf _loc (Pcf_virt (mn, Private, pte)))))));
        Decap.fsequence_position constraint_kw
          (Decap.fsequence typexpr
             (Decap.sequence (Decap.char '=' '=') typexpr
                (fun _  te'  te  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   loc_pcf _loc (Pcf_constr (te, te')))));
        Decap.sequence_position initializer_kw expr
          (fun _  e  __loc__start__buf  __loc__start__pos  __loc__end__buf 
             __loc__end__pos  ->
             let _loc =
               locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                 __loc__end__pos in
             loc_pcf _loc (Pcf_init e))]
    let _ =
      set_grammar class_body
        (Decap.sequence
           (locate
              (Decap.option None (Decap.apply (fun x  -> Some x) pattern)))
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l) class_field)))
           (fun p  ->
              let (_loc_p,p) = p in
              fun f  ->
                let p =
                  match p with
                  | None  -> loc_pat _loc_p Ppat_any
                  | Some p -> p in
                { pcstr_pat = p; pcstr_fields = f }))
    let class_binding =
      Decap.fsequence_position virtual_flag
        (Decap.fsequence
           (locate
              (Decap.option []
                 (Decap.fsequence (Decap.string "[" "[")
                    (Decap.sequence type_parameters (Decap.string "]" "]")
                       (fun params  _  _  -> params)))))
           (Decap.fsequence (locate class_name)
              (Decap.fsequence
                 (Decap.apply List.rev
                    (Decap.fixpoint []
                       (Decap.apply (fun x  l  -> x :: l) (parameter false))))
                 (Decap.fsequence
                    (Decap.option None
                       (Decap.apply (fun x  -> Some x)
                          (Decap.sequence (Decap.string ":" ":") class_type
                             (fun _  ct  -> ct))))
                    (Decap.sequence (Decap.char '=' '=') class_expr
                       (fun _  ce  ct  ps  cn  ->
                          let (_loc_cn,cn) = cn in
                          fun params  ->
                            let (_loc_params,params) = params in
                            fun v  __loc__start__buf  __loc__start__pos 
                              __loc__end__buf  __loc__end__pos  ->
                              let _loc =
                                locate2 __loc__start__buf __loc__start__pos
                                  __loc__end__buf __loc__end__pos in
                              let ce = apply_params_cls _loc ps ce in
                              let ce =
                                match ct with
                                | None  -> ce
                                | Some ct ->
                                    loc_pcl _loc (Pcl_constraint (ce, ct)) in
                              class_type_declaration _loc_params _loc
                                (id_loc cn _loc_cn) params v ce))))))
    let class_definition =
      Decap.sequence class_binding
        (Decap.apply List.rev
           (Decap.fixpoint []
              (Decap.apply (fun x  l  -> x :: l)
                 (Decap.sequence and_kw class_binding (fun _  cb  -> cb)))))
        (fun cb  cbs  -> cb :: cbs)
    let module_expr = declare_grammar "module_expr"
    let module_type = declare_grammar "module_type"
    let pexp_list _loc ?loc_cl  l =
      if l = []
      then loc_expr _loc (pexp_construct ((id_loc (Lident "[]") _loc), None))
      else
        (let loc_cl = match loc_cl with | None  -> _loc | Some pos -> pos in
         List.fold_right
           (fun (x,pos)  acc  ->
              let _loc = merge2 pos loc_cl in
              loc_expr _loc
                (pexp_construct
                   ((id_loc (Lident "::") _loc),
                     (Some (loc_expr _loc (Pexp_tuple [x; acc])))))) l
           (loc_expr loc_cl
              (pexp_construct ((id_loc (Lident "[]") loc_cl), None))))
    let expression_base =
      memoize1
        (fun lvl  ->
           Decap.alternatives'
             ((Decap.apply (fun e  -> e) (alternatives extra_expressions)) ::
             (let y =
                (Decap.apply_position
                   (fun id  ->
                      let (_loc_id,id) = id in
                      fun __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        (Atom,
                          (loc_expr _loc (Pexp_ident (id_loc id _loc_id)))))
                   (locate value_path))
                ::
                (Decap.apply_position
                   (fun c  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      (Atom, (loc_expr _loc (Pexp_constant c)))) constant)
                ::
                (Decap.fsequence_position (locate module_path)
                   (Decap.fsequence (Decap.string "." ".")
                      (Decap.fsequence (Decap.string "(" "(")
                         (Decap.sequence expression (Decap.string ")" ")")
                            (fun e  _  _  _  mp  ->
                               let (_loc_mp,mp) = mp in
                               fun __loc__start__buf  __loc__start__pos 
                                 __loc__end__buf  __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 let mp = id_loc mp _loc_mp in
                                 (Atom,
                                   (loc_expr _loc (Pexp_open (Fresh, mp, e)))))))))
                ::
                (Decap.sequence_position let_kw
                   (Decap.alternatives'
                      (let y =
                         let y =
                           let y = [] in
                           if lvl < App
                           then
                             (Decap.fsequence_position open_kw
                                (Decap.fsequence override_flag
                                   (Decap.fsequence (locate module_path)
                                      (Decap.sequence in_kw
                                         (expression_lvl (let_prio lvl))
                                         (fun _  e  mp  ->
                                            let (_loc_mp,mp) = mp in
                                            fun o  _  __loc__start__buf 
                                              __loc__start__pos 
                                              __loc__end__buf 
                                              __loc__end__pos  ->
                                              let _loc =
                                                locate2 __loc__start__buf
                                                  __loc__start__pos
                                                  __loc__end__buf
                                                  __loc__end__pos in
                                              let mp = id_loc mp _loc_mp in
                                              fun _loc  ->
                                                (Let,
                                                  (loc_expr _loc
                                                     (Pexp_open (o, mp, e)))))))))
                             :: y
                           else y in
                         if lvl < App
                         then
                           (Decap.fsequence_position module_kw
                              (Decap.fsequence (locate module_name)
                                 (Decap.fsequence
                                    (Decap.apply List.rev
                                       (Decap.fixpoint []
                                          (Decap.apply (fun x  l  -> x :: l)
                                             (Decap.fsequence_position
                                                (Decap.string "(" "(")
                                                (Decap.fsequence
                                                   (locate module_name)
                                                   (Decap.fsequence
                                                      (Decap.string ":" ":")
                                                      (Decap.sequence
                                                         module_type
                                                         (Decap.string ")"
                                                            ")")
                                                         (fun mt  _  _  mn 
                                                            ->
                                                            let (_loc_mn,mn)
                                                              = mn in
                                                            fun _ 
                                                              __loc__start__buf
                                                               __loc__start__pos
                                                               __loc__end__buf
                                                               __loc__end__pos
                                                               ->
                                                              let _loc =
                                                                locate2
                                                                  __loc__start__buf
                                                                  __loc__start__pos
                                                                  __loc__end__buf
                                                                  __loc__end__pos in
                                                              ((id_loc mn
                                                                  _loc_mn),
                                                                mt, _loc)))))))))
                                    (Decap.fsequence
                                       (locate
                                          (Decap.option None
                                             (Decap.apply (fun x  -> Some x)
                                                (Decap.sequence
                                                   (Decap.string ":" ":")
                                                   module_type
                                                   (fun _  mt  -> mt)))))
                                       (Decap.fsequence
                                          (Decap.string "=" "=")
                                          (Decap.fsequence
                                             (locate module_expr)
                                             (Decap.sequence in_kw
                                                (expression_lvl
                                                   (let_prio lvl))
                                                (fun _  e  me  ->
                                                   let (_loc_me,me) = me in
                                                   fun _  mt  ->
                                                     let (_loc_mt,mt) = mt in
                                                     fun l  mn  ->
                                                       let (_loc_mn,mn) = mn in
                                                       fun _ 
                                                         __loc__start__buf 
                                                         __loc__start__pos 
                                                         __loc__end__buf 
                                                         __loc__end__pos  ->
                                                         let _loc =
                                                           locate2
                                                             __loc__start__buf
                                                             __loc__start__pos
                                                             __loc__end__buf
                                                             __loc__end__pos in
                                                         let me =
                                                           match mt with
                                                           | None  -> me
                                                           | Some mt ->
                                                               mexpr_loc
                                                                 (merge2
                                                                    _loc_mt
                                                                    _loc_me)
                                                                 (Pmod_constraint
                                                                    (me, mt)) in
                                                         let me =
                                                           List.fold_left
                                                             (fun acc 
                                                                (mn,mt,_loc) 
                                                                ->
                                                                mexpr_loc
                                                                  (merge2
                                                                    _loc
                                                                    _loc_me)
                                                                  (Pmod_functor
                                                                    (mn, mt,
                                                                    acc))) me
                                                             (List.rev l) in
                                                         fun _loc  ->
                                                           (Let,
                                                             (loc_expr _loc
                                                                (Pexp_letmodule
                                                                   ((id_loc
                                                                    mn
                                                                    _loc_mn),
                                                                    me, e))))))))))))
                           :: y
                         else y in
                       if lvl < App
                       then
                         (Decap.fsequence_position rec_flag
                            (Decap.fsequence let_binding
                               (Decap.sequence in_kw
                                  (expression_lvl (let_prio lvl))
                                  (fun _  e  l  r  __loc__start__buf 
                                     __loc__start__pos  __loc__end__buf 
                                     __loc__end__pos  ->
                                     let _loc =
                                       locate2 __loc__start__buf
                                         __loc__start__pos __loc__end__buf
                                         __loc__end__pos in
                                     fun _loc  ->
                                       (Let,
                                         (loc_expr _loc (Pexp_let (r, l, e))))))))
                         :: y
                       else y))
                   (fun _  r  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      r _loc))
                ::
                (let y =
                   let y =
                     let y =
                       let y =
                         let y =
                           (Decap.fsequence_position (Decap.string "(" "(")
                              (Decap.sequence
                                 (Decap.option None
                                    (Decap.apply (fun x  -> Some x)
                                       expression)) (Decap.string ")" ")")
                                 (fun e  _  _  __loc__start__buf 
                                    __loc__start__pos  __loc__end__buf 
                                    __loc__end__pos  ->
                                    let _loc =
                                      locate2 __loc__start__buf
                                        __loc__start__pos __loc__end__buf
                                        __loc__end__pos in
                                    (Atom,
                                      (match e with
                                       | Some e -> loc_expr _loc e.pexp_desc
                                       | None  ->
                                           let cunit =
                                             id_loc (Lident "()") _loc in
                                           loc_expr _loc
                                             (pexp_construct (cunit, None)))))))
                           ::
                           (Decap.fsequence_position begin_kw
                              (Decap.sequence
                                 (Decap.option None
                                    (Decap.apply (fun x  -> Some x)
                                       expression)) end_kw
                                 (fun e  _  _  __loc__start__buf 
                                    __loc__start__pos  __loc__end__buf 
                                    __loc__end__pos  ->
                                    let _loc =
                                      locate2 __loc__start__buf
                                        __loc__start__pos __loc__end__buf
                                        __loc__end__pos in
                                    (Atom,
                                      (match e with
                                       | Some e -> e
                                       | None  ->
                                           let cunit =
                                             id_loc (Lident "()") _loc in
                                           loc_expr _loc
                                             (pexp_construct (cunit, None)))))))
                           ::
                           (Decap.sequence_position (locate constructor)
                              (Decap.option None
                                 (Decap.apply (fun x  -> Some x)
                                    (if lvl <= App
                                     then
                                       Decap.apply (fun e  -> e)
                                         (expression_lvl (next_exp App))
                                     else Decap.fail "")))
                              (fun c  ->
                                 let (_loc_c,c) = c in
                                 fun e  __loc__start__buf  __loc__start__pos 
                                   __loc__end__buf  __loc__end__pos  ->
                                   let _loc =
                                     locate2 __loc__start__buf
                                       __loc__start__pos __loc__end__buf
                                       __loc__end__pos in
                                   (App,
                                     (loc_expr _loc
                                        (pexp_construct
                                           ((id_loc c _loc_c), e))))))
                           ::
                           (let y =
                              let y =
                                let y =
                                  [Decap.apply_position
                                     (fun l  __loc__start__buf 
                                        __loc__start__pos  __loc__end__buf 
                                        __loc__end__pos  ->
                                        let _loc =
                                          locate2 __loc__start__buf
                                            __loc__start__pos __loc__end__buf
                                            __loc__end__pos in
                                        (Atom,
                                          (loc_expr _loc
                                             (Pexp_variant (l, None)))))
                                     tag_name;
                                  Decap.fsequence_position
                                    (Decap.string "[|" "[|")
                                    (Decap.sequence expression_list
                                       (Decap.string "|]" "|]")
                                       (fun l  _  _  __loc__start__buf 
                                          __loc__start__pos  __loc__end__buf 
                                          __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          (Atom,
                                            (loc_expr _loc
                                               (Pexp_array (List.map fst l))))));
                                  Decap.fsequence_position
                                    (Decap.string "[" "[")
                                    (Decap.sequence expression_list
                                       (locate (Decap.string "]" "]"))
                                       (fun l  cl  ->
                                          let (_loc_cl,cl) = cl in
                                          fun _  __loc__start__buf 
                                            __loc__start__pos 
                                            __loc__end__buf  __loc__end__pos 
                                            ->
                                            let _loc =
                                              locate2 __loc__start__buf
                                                __loc__start__pos
                                                __loc__end__buf
                                                __loc__end__pos in
                                            (Atom,
                                              (loc_expr _loc
                                                 (pexp_list _loc
                                                    ~loc_cl:_loc_cl l).pexp_desc))));
                                  Decap.fsequence_position
                                    (Decap.string "{" "{")
                                    (Decap.fsequence
                                       (Decap.option None
                                          (Decap.apply (fun x  -> Some x)
                                             (Decap.sequence
                                                (expression_lvl
                                                   (next_exp Seq)) with_kw
                                                (fun e  _  -> e))))
                                       (Decap.sequence record_list
                                          (Decap.string "}" "}")
                                          (fun l  _  e  _  __loc__start__buf 
                                             __loc__start__pos 
                                             __loc__end__buf  __loc__end__pos
                                              ->
                                             let _loc =
                                               locate2 __loc__start__buf
                                                 __loc__start__pos
                                                 __loc__end__buf
                                                 __loc__end__pos in
                                             (Atom,
                                               (loc_expr _loc
                                                  (Pexp_record (l, e)))))));
                                  Decap.fsequence_position while_kw
                                    (Decap.fsequence expression
                                       (Decap.fsequence do_kw
                                          (Decap.sequence expression done_kw
                                             (fun e'  _  _  e  _ 
                                                __loc__start__buf 
                                                __loc__start__pos 
                                                __loc__end__buf 
                                                __loc__end__pos  ->
                                                let _loc =
                                                  locate2 __loc__start__buf
                                                    __loc__start__pos
                                                    __loc__end__buf
                                                    __loc__end__pos in
                                                (Atom,
                                                  (loc_expr _loc
                                                     (Pexp_while (e, e'))))))));
                                  Decap.fsequence_position for_kw
                                    (Decap.fsequence (locate lowercase_ident)
                                       (Decap.fsequence (Decap.char '=' '=')
                                          (Decap.fsequence expression
                                             (Decap.fsequence downto_flag
                                                (Decap.fsequence expression
                                                   (Decap.fsequence do_kw
                                                      (Decap.sequence
                                                         expression done_kw
                                                         (fun e''  _  _  e' 
                                                            d  e  _  id  ->
                                                            let (_loc_id,id)
                                                              = id in
                                                            fun _ 
                                                              __loc__start__buf
                                                               __loc__start__pos
                                                               __loc__end__buf
                                                               __loc__end__pos
                                                               ->
                                                              let _loc =
                                                                locate2
                                                                  __loc__start__buf
                                                                  __loc__start__pos
                                                                  __loc__end__buf
                                                                  __loc__end__pos in
                                                              (Atom,
                                                                (loc_expr
                                                                   _loc
                                                                   (Pexp_for
                                                                    ((id_loc
                                                                    id
                                                                    _loc_id),
                                                                    e, e', d,
                                                                    e''))))))))))));
                                  Decap.sequence_position new_kw
                                    (locate class_path)
                                    (fun _  p  ->
                                       let (_loc_p,p) = p in
                                       fun __loc__start__buf 
                                         __loc__start__pos  __loc__end__buf 
                                         __loc__end__pos  ->
                                         let _loc =
                                           locate2 __loc__start__buf
                                             __loc__start__pos
                                             __loc__end__buf __loc__end__pos in
                                         (Atom,
                                           (loc_expr _loc
                                              (Pexp_new (id_loc p _loc_p)))));
                                  Decap.fsequence_position object_kw
                                    (Decap.sequence class_body end_kw
                                       (fun o  _  _  __loc__start__buf 
                                          __loc__start__pos  __loc__end__buf 
                                          __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          (Atom,
                                            (loc_expr _loc (Pexp_object o)))));
                                  Decap.fsequence_position
                                    (Decap.string "{<" "{<")
                                    (Decap.sequence
                                       (Decap.option []
                                          (Decap.fsequence obj_item
                                             (Decap.sequence
                                                (Decap.apply List.rev
                                                   (Decap.fixpoint []
                                                      (Decap.apply
                                                         (fun x  l  -> x :: l)
                                                         (Decap.sequence
                                                            (Decap.string ";"
                                                               ";") obj_item
                                                            (fun _  o  -> o)))))
                                                (Decap.option None
                                                   (Decap.apply
                                                      (fun x  -> Some x)
                                                      (Decap.string ";" ";")))
                                                (fun l  _  o  -> o :: l))))
                                       (Decap.string ">}" ">}")
                                       (fun l  _  _  __loc__start__buf 
                                          __loc__start__pos  __loc__end__buf 
                                          __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          (Atom,
                                            (loc_expr _loc (Pexp_override l)))));
                                  Decap.fsequence_position
                                    (Decap.string "(" "(")
                                    (Decap.fsequence module_kw
                                       (Decap.fsequence (locate module_expr)
                                          (Decap.sequence
                                             (locate
                                                (Decap.option None
                                                   (Decap.apply
                                                      (fun x  -> Some x)
                                                      (Decap.sequence
                                                         (Decap.string ":"
                                                            ":") package_type
                                                         (fun _  pt  -> pt)))))
                                             (Decap.string ")" ")")
                                             (fun pt  ->
                                                let (_loc_pt,pt) = pt in
                                                fun _  me  ->
                                                  let (_loc_me,me) = me in
                                                  fun _  _  __loc__start__buf
                                                     __loc__start__pos 
                                                    __loc__end__buf 
                                                    __loc__end__pos  ->
                                                    let _loc =
                                                      locate2
                                                        __loc__start__buf
                                                        __loc__start__pos
                                                        __loc__end__buf
                                                        __loc__end__pos in
                                                    let desc =
                                                      match pt with
                                                      | None  -> Pexp_pack me
                                                      | Some pt ->
                                                          let me =
                                                            loc_expr _loc_me
                                                              (Pexp_pack me) in
                                                          let pt =
                                                            loc_typ _loc_pt
                                                              pt in
                                                          pexp_constraint
                                                            (me, pt) in
                                                    (Atom,
                                                      (loc_expr _loc desc))))));
                                  Decap.fsequence (Decap.string "<:" "<:")
                                    (Decap.fsequence
                                       (Decap.alternatives'
                                          [Decap.apply
                                             (fun _  -> "expression")
                                             (Decap.string "expr" "expr");
                                          Decap.apply (fun _  -> "type")
                                            (Decap.string "type" "type");
                                          Decap.apply (fun _  -> "pattern")
                                            (Decap.string "pat" "pat");
                                          Decap.apply (fun _  -> "structure")
                                            (Decap.string "structure"
                                               "structure");
                                          Decap.apply (fun _  -> "signature")
                                            (Decap.string "signature"
                                               "signature")])
                                       (Decap.fsequence
                                          (Decap.option None
                                             (Decap.apply (fun x  -> Some x)
                                                (Decap.sequence
                                                   (Decap.char '@' '@')
                                                   (expression_lvl
                                                      (next_exp App))
                                                   (fun _  e  -> e))))
                                          (Decap.sequence
                                             (Decap.char '<' '<')
                                             (locate quotation)
                                             (fun _  q  ->
                                                let (_loc_q,q) = q in
                                                fun loc  name  _  ->
                                                  if loc = None
                                                  then push_location "";
                                                  (Atom,
                                                    (quote_expression _loc_q
                                                       loc q name))))));
                                  Decap.sequence_position
                                    (Decap.char '$' '$') capitalized_ident
                                    (fun _  c  __loc__start__buf 
                                       __loc__start__pos  __loc__end__buf 
                                       __loc__end__pos  ->
                                       let _loc =
                                         locate2 __loc__start__buf
                                           __loc__start__pos __loc__end__buf
                                           __loc__end__pos in
                                       (Atom,
                                         (match c with
                                          | "FILE" ->
                                              loc_expr _loc
                                                (Pexp_constant
                                                   (const_string
                                                      (start_pos _loc).Lexing.pos_fname))
                                          | "LINE" ->
                                              loc_expr _loc
                                                (Pexp_constant
                                                   (Const_int
                                                      ((start_pos _loc).Lexing.pos_lnum)))
                                          | _ ->
                                              (try
                                                 let str = Sys.getenv c in
                                                 parse_string
                                                   ~filename:("ENV:" ^ c)
                                                   expression blank str
                                               with
                                               | Not_found  -> raise Give_up))));
                                  Decap.fsequence_position
                                    (Decap.char '$' '$')
                                    (Decap.fsequence
                                       (Decap.option None
                                          (Decap.apply (fun x  -> Some x)
                                             (Decap.sequence
                                                (Decap.alternatives'
                                                   [Decap.apply
                                                      (fun _  -> "tuple")
                                                      (Decap.string "tuple"
                                                         "tuple");
                                                   Decap.apply
                                                     (fun _  -> "list")
                                                     (Decap.string "list"
                                                        "list");
                                                   Decap.apply
                                                     (fun _  -> "array")
                                                     (Decap.string "array"
                                                        "array")])
                                                (Decap.char ':' ':')
                                                (fun t  _  -> t))))
                                       (Decap.sequence
                                          (expression_lvl (next_exp App))
                                          (Decap.char '$' '$')
                                          (fun e  _  t  _  __loc__start__buf 
                                             __loc__start__pos 
                                             __loc__end__buf  __loc__end__pos
                                              ->
                                             let _loc =
                                               locate2 __loc__start__buf
                                                 __loc__start__pos
                                                 __loc__end__buf
                                                 __loc__end__pos in
                                             match t with
                                             | None  ->
                                                 (Atom,
                                                   (push_pop_expression e))
                                             | Some str ->
                                                 let l =
                                                   push_pop_expression_list e in
                                                 (match str with
                                                  | "tuple" ->
                                                      (Atom,
                                                        (loc_expr _loc
                                                           (Pexp_tuple l)))
                                                  | "array" ->
                                                      (Atom,
                                                        (loc_expr _loc
                                                           (Pexp_array l)))
                                                  | "list" ->
                                                      let l =
                                                        List.map
                                                          (fun x  ->
                                                             (x, _loc)) l in
                                                      (Atom,
                                                        (loc_expr _loc
                                                           (pexp_list _loc l).pexp_desc))
                                                  | _ -> raise Give_up))));
                                  Decap.iter
                                    (Decap.apply
                                       (fun p  ->
                                          let (_loc_p,p) = p in
                                          let lvl' = prefix_prio p in
                                          if lvl <= lvl'
                                          then
                                            Decap.apply
                                              (fun e  ->
                                                 let (_loc_e,e) = e in
                                                 (lvl',
                                                   (mk_unary_opp p _loc_p e
                                                      _loc_e)))
                                              (locate (expression_lvl lvl'))
                                          else Decap.fail "")
                                       (locate prefix_symbol))] in
                                if lvl <= App
                                then
                                  (Decap.sequence_position tag_name
                                     (expression_lvl (next_exp App))
                                     (fun l  e  __loc__start__buf 
                                        __loc__start__pos  __loc__end__buf 
                                        __loc__end__pos  ->
                                        let _loc =
                                          locate2 __loc__start__buf
                                            __loc__start__pos __loc__end__buf
                                            __loc__end__pos in
                                        (App,
                                          (loc_expr _loc
                                             (Pexp_variant (l, (Some e)))))))
                                  :: y
                                else y in
                              if lvl <= App
                              then
                                (Decap.sequence_position lazy_kw
                                   (expression_lvl App)
                                   (fun _  e  __loc__start__buf 
                                      __loc__start__pos  __loc__end__buf 
                                      __loc__end__pos  ->
                                      let _loc =
                                        locate2 __loc__start__buf
                                          __loc__start__pos __loc__end__buf
                                          __loc__end__pos in
                                      (App, (loc_expr _loc (Pexp_lazy e)))))
                                :: y
                              else y in
                            if lvl <= App
                            then
                              (Decap.sequence_position assert_kw
                                 (Decap.alternatives'
                                    [Decap.apply_position
                                       (fun _  __loc__start__buf 
                                          __loc__start__pos  __loc__end__buf 
                                          __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          pexp_assertfalse _loc) false_kw;
                                    Decap.apply (fun e  -> Pexp_assert e)
                                      (expression_lvl App)])
                                 (fun _  e  __loc__start__buf 
                                    __loc__start__pos  __loc__end__buf 
                                    __loc__end__pos  ->
                                    let _loc =
                                      locate2 __loc__start__buf
                                        __loc__start__pos __loc__end__buf
                                        __loc__end__pos in
                                    (App, (loc_expr _loc e))))
                              :: y
                            else y) in
                         if lvl < App
                         then
                           (Decap.fsequence_position if_kw
                              (Decap.fsequence expression
                                 (Decap.fsequence then_kw
                                    (Decap.sequence (expression_lvl If)
                                       (Decap.option None
                                          (Decap.apply (fun x  -> Some x)
                                             (Decap.sequence else_kw
                                                (expression_lvl If)
                                                (fun _  e  -> e))))
                                       (fun e  e'  _  c  _  __loc__start__buf
                                           __loc__start__pos  __loc__end__buf
                                           __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          (If,
                                            (loc_expr _loc
                                               (Pexp_ifthenelse (c, e, e')))))))))
                           :: y
                         else y in
                       if lvl < App
                       then
                         (Decap.fsequence_position try_kw
                            (Decap.fsequence expression
                               (Decap.sequence with_kw
                                  (match_cases (let_prio lvl))
                                  (fun _  l  e  _  __loc__start__buf 
                                     __loc__start__pos  __loc__end__buf 
                                     __loc__end__pos  ->
                                     let _loc =
                                       locate2 __loc__start__buf
                                         __loc__start__pos __loc__end__buf
                                         __loc__end__pos in
                                     (Let, (loc_expr _loc (Pexp_try (e, l))))))))
                         :: y
                       else y in
                     if lvl < App
                     then
                       (Decap.fsequence_position match_kw
                          (Decap.fsequence expression
                             (Decap.sequence with_kw
                                (match_cases (let_prio lvl))
                                (fun _  l  e  _  __loc__start__buf 
                                   __loc__start__pos  __loc__end__buf 
                                   __loc__end__pos  ->
                                   let _loc =
                                     locate2 __loc__start__buf
                                       __loc__start__pos __loc__end__buf
                                       __loc__end__pos in
                                   (Let, (loc_expr _loc (Pexp_match (e, l))))))))
                       :: y
                     else y in
                   if lvl < App
                   then
                     (Decap.fsequence_position fun_kw
                        (Decap.fsequence
                           (Decap.apply List.rev
                              (Decap.fixpoint []
                                 (Decap.apply (fun x  l  -> x :: l)
                                    (Decap.apply
                                       (fun lbl  ->
                                          let (_loc_lbl,lbl) = lbl in
                                          (lbl, _loc_lbl))
                                       (locate (parameter true))))))
                           (Decap.sequence (Decap.string "->" "->")
                              (expression_lvl (let_prio lvl))
                              (fun _  e  l  _  __loc__start__buf 
                                 __loc__start__pos  __loc__end__buf 
                                 __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 (Let,
                                   (loc_expr _loc
                                      (apply_params l e).pexp_desc))))))
                     :: y
                   else y in
                 if lvl < App
                 then
                   (Decap.sequence_position function_kw
                      (match_cases (let_prio lvl))
                      (fun _  l  __loc__start__buf  __loc__start__pos 
                         __loc__end__buf  __loc__end__pos  ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         (Let, (loc_expr _loc (pexp_function l)))))
                   :: y
                 else y) in
              if lvl <= Aff
              then
                (Decap.fsequence_position (locate inst_var_name)
                   (Decap.sequence (Decap.string "<-" "<-")
                      (expression_lvl (next_exp Aff))
                      (fun _  e  v  ->
                         let (_loc_v,v) = v in
                         fun __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           (Aff,
                             (loc_expr _loc
                                (Pexp_setinstvar ((id_loc v _loc_v), e)))))))
                :: y
              else y)))
    let apply_lbl _loc (lbl,e) =
      let e =
        match e with
        | None  -> loc_expr _loc (Pexp_ident (id_loc (Lident lbl) _loc))
        | Some e -> e in
      (lbl, e)
    let rec mk_seq =
      function
      | [] -> assert false
      | e::[] -> e
      | x::l ->
          let res = mk_seq l in
          loc_expr (merge2 x.pexp_loc res.pexp_loc) (Pexp_sequence (x, res))
    let semi_col =
      black_box
        (fun str  pos  ->
           let (c,str',pos') = read str pos in
           if c = ';'
           then
             let (c',_,_) = read str' pos' in
             (if c' = ';' then raise Give_up else ((), str', pos'))
           else raise Give_up) (Charset.singleton ';') false ";"
    let double_semi_col =
      black_box
        (fun str  pos  ->
           let (c,str',pos') = read str pos in
           if c = ';'
           then
             let (c',_,_) = read str' pos' in
             (if c' <> ';' then raise Give_up else ((), str', pos'))
           else raise Give_up) (Charset.singleton ';') false ";;"
    let expression_suit_aux =
      memoize2
        (fun lvl'  lvl  ->
           let ln f _loc e = loc_expr (merge2 f.pexp_loc _loc) e in
           Decap.alternatives'
             (let y =
                let y =
                  let y =
                    let y =
                      (Decap.sequence (Decap.string "." ".")
                         (Decap.alternatives'
                            (let y =
                               let y =
                                 let y =
                                   let y =
                                     let y =
                                       let y =
                                         let y =
                                           let y = [] in
                                           if (lvl' >= Dot) && (lvl <= Dot)
                                           then
                                             (Decap.apply_position
                                                (fun f  ->
                                                   let (_loc_f,f) = f in
                                                   fun __loc__start__buf 
                                                     __loc__start__pos 
                                                     __loc__end__buf 
                                                     __loc__end__pos  ->
                                                     let _loc =
                                                       locate2
                                                         __loc__start__buf
                                                         __loc__start__pos
                                                         __loc__end__buf
                                                         __loc__end__pos in
                                                     (Dot,
                                                       (fun e'  ->
                                                          let f =
                                                            id_loc f _loc_f in
                                                          loc_expr _loc
                                                            (Pexp_field
                                                               (e', f)))))
                                                (locate field))
                                             :: y
                                           else y in
                                         if (lvl' >= Aff) && (lvl <= Aff)
                                         then
                                           (Decap.fsequence_position
                                              (locate field)
                                              (Decap.sequence
                                                 (Decap.string "<-" "<-")
                                                 (expression_lvl
                                                    (next_exp Aff))
                                                 (fun _  e  f  ->
                                                    let (_loc_f,f) = f in
                                                    fun __loc__start__buf 
                                                      __loc__start__pos 
                                                      __loc__end__buf 
                                                      __loc__end__pos  ->
                                                      let _loc =
                                                        locate2
                                                          __loc__start__buf
                                                          __loc__start__pos
                                                          __loc__end__buf
                                                          __loc__end__pos in
                                                      (Aff,
                                                        (fun e'  ->
                                                           let f =
                                                             id_loc f _loc_f in
                                                           loc_expr _loc
                                                             (Pexp_setfield
                                                                (e', f, e)))))))
                                           :: y
                                         else y in
                                       if (lvl' >= Dot) && (lvl <= Dot)
                                       then
                                         (Decap.fsequence_position
                                            (Decap.string "{" "{")
                                            (Decap.sequence expression
                                               (Decap.string "}" "}")
                                               (fun f  _  _ 
                                                  __loc__start__buf 
                                                  __loc__start__pos 
                                                  __loc__end__buf 
                                                  __loc__end__pos  ->
                                                  let _loc =
                                                    locate2 __loc__start__buf
                                                      __loc__start__pos
                                                      __loc__end__buf
                                                      __loc__end__pos in
                                                  (Dot,
                                                    (fun e'  ->
                                                       bigarray_get
                                                         (merge2 e'.pexp_loc
                                                            _loc) e' f)))))
                                         :: y
                                       else y in
                                     if (lvl' >= Aff) && (lvl <= Aff)
                                     then
                                       (Decap.fsequence_position
                                          (Decap.string "{" "{")
                                          (Decap.fsequence expression
                                             (Decap.fsequence
                                                (Decap.string "}" "}")
                                                (Decap.sequence
                                                   (Decap.string "<-" "<-")
                                                   (expression_lvl
                                                      (next_exp Aff))
                                                   (fun _  e  _  f  _ 
                                                      __loc__start__buf 
                                                      __loc__start__pos 
                                                      __loc__end__buf 
                                                      __loc__end__pos  ->
                                                      let _loc =
                                                        locate2
                                                          __loc__start__buf
                                                          __loc__start__pos
                                                          __loc__end__buf
                                                          __loc__end__pos in
                                                      (Aff,
                                                        (fun e'  ->
                                                           bigarray_set
                                                             (merge2
                                                                e'.pexp_loc
                                                                _loc) e' f e)))))))
                                       :: y
                                     else y in
                                   if (lvl' >= Dot) && (lvl <= Dot)
                                   then
                                     (Decap.fsequence_position
                                        (Decap.string "[" "[")
                                        (Decap.sequence expression
                                           (Decap.string "]" "]")
                                           (fun f  _  _  __loc__start__buf 
                                              __loc__start__pos 
                                              __loc__end__buf 
                                              __loc__end__pos  ->
                                              let _loc =
                                                locate2 __loc__start__buf
                                                  __loc__start__pos
                                                  __loc__end__buf
                                                  __loc__end__pos in
                                              (Dot,
                                                (fun e'  ->
                                                   ln e' _loc
                                                     (Pexp_apply
                                                        ((array_function
                                                            (merge2
                                                               e'.pexp_loc
                                                               _loc) "String"
                                                            "get"),
                                                          [("", e'); ("", f)])))))))
                                     :: y
                                   else y in
                                 if (lvl' >= Aff) && (lvl <= Aff)
                                 then
                                   (Decap.fsequence_position
                                      (Decap.string "[" "[")
                                      (Decap.fsequence expression
                                         (Decap.fsequence
                                            (Decap.string "]" "]")
                                            (Decap.sequence
                                               (Decap.string "<-" "<-")
                                               (expression_lvl (next_exp Aff))
                                               (fun _  e  _  f  _ 
                                                  __loc__start__buf 
                                                  __loc__start__pos 
                                                  __loc__end__buf 
                                                  __loc__end__pos  ->
                                                  let _loc =
                                                    locate2 __loc__start__buf
                                                      __loc__start__pos
                                                      __loc__end__buf
                                                      __loc__end__pos in
                                                  (Aff,
                                                    (fun e'  ->
                                                       ln e' _loc
                                                         (Pexp_apply
                                                            ((array_function
                                                                (merge2
                                                                   e'.pexp_loc
                                                                   _loc)
                                                                "String"
                                                                "set"),
                                                              [("", e');
                                                              ("", f);
                                                              ("", e)])))))))))
                                   :: y
                                 else y in
                               if (lvl' >= Dot) && (lvl <= Dot)
                               then
                                 (Decap.fsequence_position
                                    (Decap.string "(" "(")
                                    (Decap.sequence expression
                                       (Decap.string ")" ")")
                                       (fun f  _  _  __loc__start__buf 
                                          __loc__start__pos  __loc__end__buf 
                                          __loc__end__pos  ->
                                          let _loc =
                                            locate2 __loc__start__buf
                                              __loc__start__pos
                                              __loc__end__buf __loc__end__pos in
                                          (Dot,
                                            (fun e'  ->
                                               ln e' _loc
                                                 (Pexp_apply
                                                    ((array_function
                                                        (merge2 e'.pexp_loc
                                                           _loc) "Array"
                                                        "get"),
                                                      [("", e'); ("", f)])))))))
                                 :: y
                               else y in
                             if (lvl' > Aff) && (lvl <= Aff)
                             then
                               (Decap.fsequence_position
                                  (Decap.string "(" "(")
                                  (Decap.fsequence expression
                                     (Decap.fsequence (Decap.string ")" ")")
                                        (Decap.sequence
                                           (Decap.string "<-" "<-")
                                           (expression_lvl (next_exp Aff))
                                           (fun _  e  _  f  _ 
                                              __loc__start__buf 
                                              __loc__start__pos 
                                              __loc__end__buf 
                                              __loc__end__pos  ->
                                              let _loc =
                                                locate2 __loc__start__buf
                                                  __loc__start__pos
                                                  __loc__end__buf
                                                  __loc__end__pos in
                                              (Aff,
                                                (fun e'  ->
                                                   ln e' _loc
                                                     (Pexp_apply
                                                        ((array_function
                                                            (merge2
                                                               e'.pexp_loc
                                                               _loc) "Array"
                                                            "set"),
                                                          [("", e');
                                                          ("", f);
                                                          ("", e)])))))))))
                               :: y
                             else y)) (fun _  r  -> r))
                      ::
                      (let y =
                         let y =
                           [Decap.iter
                              (Decap.apply
                                 (fun op  ->
                                    let (_loc_op,op) = op in
                                    let p = infix_prio op in
                                    let a = assoc p in
                                    if
                                      (lvl <= p) &&
                                        ((lvl' > p) ||
                                           ((a = Left) && (lvl' = p)))
                                    then
                                      Decap.apply_position
                                        (fun e  __loc__start__buf 
                                           __loc__start__pos  __loc__end__buf
                                            __loc__end__pos  ->
                                           let _loc =
                                             locate2 __loc__start__buf
                                               __loc__start__pos
                                               __loc__end__buf
                                               __loc__end__pos in
                                           (p,
                                             (fun e'  ->
                                                ln e' e.pexp_loc
                                                  (if op = "::"
                                                   then
                                                     pexp_construct
                                                       ((id_loc (Lident "::")
                                                           _loc_op),
                                                         (Some
                                                            (ln e' _loc
                                                               (Pexp_tuple
                                                                  [e'; e]))))
                                                   else
                                                     Pexp_apply
                                                       ((loc_expr _loc_op
                                                           (Pexp_ident
                                                              (id_loc
                                                                 (Lident op)
                                                                 _loc_op))),
                                                         [("", e'); ("", e)])))))
                                        (expression_lvl
                                           (if a = Right
                                            then p
                                            else next_exp p))
                                    else Decap.fail "") (locate infix_op))] in
                         if (lvl' > App) && (lvl <= App)
                         then
                           (Decap.apply_position
                              (fun l  __loc__start__buf  __loc__start__pos 
                                 __loc__end__buf  __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 (App,
                                   (fun f  -> ln f _loc (Pexp_apply (f, l)))))
                              (Decap.sequence
                                 (Decap.apply (fun a  -> a) argument)
                                 (Decap.fixpoint []
                                    (Decap.apply (fun x  l  -> x :: l)
                                       (Decap.apply (fun a  -> a) argument)))
                                 (fun x  l  -> x :: (List.rev l))))
                           :: y
                         else y in
                       if (lvl' >= Dash) && (lvl <= Dash)
                       then
                         (Decap.sequence_position (Decap.string "#" "#")
                            method_name
                            (fun _  f  __loc__start__buf  __loc__start__pos 
                               __loc__end__buf  __loc__end__pos  ->
                               let _loc =
                                 locate2 __loc__start__buf __loc__start__pos
                                   __loc__end__buf __loc__end__pos in
                               (Dash,
                                 (fun e'  -> ln e' _loc (Pexp_send (e', f))))))
                         :: y
                       else y) in
                    if (lvl' >= Seq) && (lvl <= Seq)
                    then
                      (Decap.apply (fun _  -> (Seq, (fun e  -> e))) semi_col)
                      :: y
                    else y in
                  if (lvl' > Seq) && (lvl <= Seq)
                  then
                    (Decap.apply
                       (fun l  -> (Seq, (fun f  -> mk_seq (f :: l))))
                       (Decap.sequence
                          (Decap.sequence semi_col
                             (expression_lvl (next_exp Seq)) (fun _  e  -> e))
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                (Decap.sequence semi_col
                                   (expression_lvl (next_exp Seq))
                                   (fun _  e  -> e))))
                          (fun x  l  -> x :: (List.rev l))))
                    :: y
                  else y in
                if (lvl' > Coerce) && (lvl <= Coerce)
                then
                  (Decap.apply_position
                     (fun t  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        (Seq,
                          (fun e'  ->
                             ln e' _loc
                               (match t with
                                | (Some t1,None ) -> pexp_constraint (e', t1)
                                | (t1,Some t2) -> pexp_coerce (e', t1, t2)
                                | (None ,None ) -> assert false))))
                     type_coercion)
                  :: y
                else y in
              if (lvl' > Tupl) && (lvl <= Tupl)
              then
                (Decap.apply_position
                   (fun l  __loc__start__buf  __loc__start__pos 
                      __loc__end__buf  __loc__end__pos  ->
                      let _loc =
                        locate2 __loc__start__buf __loc__start__pos
                          __loc__end__buf __loc__end__pos in
                      (Tupl, (fun f  -> ln f _loc (Pexp_tuple (f :: l)))))
                   (Decap.sequence
                      (Decap.sequence (Decap.string "," ",")
                         (expression_lvl (next_exp Tupl)) (fun _  e  -> e))
                      (Decap.fixpoint []
                         (Decap.apply (fun x  l  -> x :: l)
                            (Decap.sequence (Decap.string "," ",")
                               (expression_lvl (next_exp Tupl))
                               (fun _  e  -> e))))
                      (fun x  l  -> x :: (List.rev l))))
                :: y
              else y))
    let expression_suit =
      let f =
        memoize2'
          (fun expression_suit  lvl'  lvl  ->
             Decap.alternatives'
               [Decap.iter
                  (Decap.apply
                     (fun (p1,f1)  ->
                        Decap.apply
                          (fun (p2,f2)  -> (p2, (fun f  -> f2 (f1 f))))
                          (expression_suit p1 lvl))
                     (expression_suit_aux lvl' lvl));
               Decap.apply (fun _  -> (lvl', (fun f  -> f))) (Decap.empty ())]) in
      let rec res x y = f res x y in res
    let _ =
      set_expression_lvl
        (fun lvl  ->
           Decap.iter
             (Decap.apply
                (fun (lvl',e)  ->
                   Decap.apply (fun (_,f)  -> f e) (expression_suit lvl' lvl))
                (expression_base lvl)))
    let module_expr_base =
      Decap.alternatives'
        [Decap.apply_position
           (fun mp  __loc__start__buf  __loc__start__pos  __loc__end__buf 
              __loc__end__pos  ->
              let _loc =
                locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                  __loc__end__pos in
              let mid = id_loc mp _loc in mexpr_loc _loc (Pmod_ident mid))
           module_path;
        Decap.fsequence_position struct_kw
          (Decap.sequence structure end_kw
             (fun ms  _  _  __loc__start__buf  __loc__start__pos 
                __loc__end__buf  __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                mexpr_loc _loc (Pmod_structure ms)));
        Decap.fsequence_position functor_kw
          (Decap.fsequence (Decap.string "(" "(")
             (Decap.fsequence (locate module_name)
                (Decap.fsequence (Decap.string ":" ":")
                   (Decap.fsequence module_type
                      (Decap.fsequence (Decap.string ")" ")")
                         (Decap.sequence (Decap.string "->" "->") module_expr
                            (fun _  me  _  mt  _  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun _  _  __loc__start__buf  __loc__start__pos
                                  __loc__end__buf  __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 mexpr_loc _loc
                                   (Pmod_functor
                                      ((id_loc mn _loc_mn), mt, me)))))))));
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence module_expr
             (Decap.sequence
                (Decap.option None
                   (Decap.apply (fun x  -> Some x)
                      (Decap.sequence (Decap.string ":" ":") module_type
                         (fun _  mt  -> mt)))) (Decap.string ")" ")")
                (fun mt  _  me  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   match mt with
                   | None  -> me
                   | Some mt -> mexpr_loc _loc (Pmod_constraint (me, mt)))));
        Decap.fsequence_position (Decap.string "(" "(")
          (Decap.fsequence val_kw
             (Decap.fsequence expr
                (Decap.sequence
                   (locate
                      (Decap.option None
                         (Decap.apply (fun x  -> Some x)
                            (Decap.sequence (Decap.string ":" ":")
                               package_type (fun _  pt  -> pt)))))
                   (Decap.string ")" ")")
                   (fun pt  ->
                      let (_loc_pt,pt) = pt in
                      fun _  e  _  _  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let e =
                          match pt with
                          | None  -> Pmod_unpack e
                          | Some pt ->
                              let pt = loc_typ _loc_pt pt in
                              Pmod_unpack
                                (loc_expr _loc (pexp_constraint (e, pt))) in
                        mexpr_loc _loc e))))]
    let _ =
      set_grammar module_expr
        (Decap.sequence (locate module_expr_base)
           (Decap.apply List.rev
              (Decap.fixpoint []
                 (Decap.apply (fun x  l  -> x :: l)
                    (Decap.fsequence_position (Decap.string "(" "(")
                       (Decap.sequence module_expr (Decap.string ")" ")")
                          (fun m  _  _  __loc__start__buf  __loc__start__pos 
                             __loc__end__buf  __loc__end__pos  ->
                             let _loc =
                               locate2 __loc__start__buf __loc__start__pos
                                 __loc__end__buf __loc__end__pos in
                             (_loc, m)))))))
           (fun m  ->
              let (_loc_m,m) = m in
              fun l  ->
                List.fold_left
                  (fun acc  (_loc_n,n)  ->
                     mexpr_loc (merge2 _loc_m _loc_n) (Pmod_apply (acc, n)))
                  m l))
    let module_type_base =
      Decap.alternatives'
        [Decap.apply_position
           (fun mp  __loc__start__buf  __loc__start__pos  __loc__end__buf 
              __loc__end__pos  ->
              let _loc =
                locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                  __loc__end__pos in
              let mid = id_loc mp _loc in mtyp_loc _loc (Pmty_ident mid))
           modtype_path;
        Decap.fsequence_position sig_kw
          (Decap.sequence signature end_kw
             (fun ms  _  _  __loc__start__buf  __loc__start__pos 
                __loc__end__buf  __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                mtyp_loc _loc (Pmty_signature ms)));
        Decap.fsequence_position functor_kw
          (Decap.fsequence (Decap.string "(" "(")
             (Decap.fsequence (locate module_name)
                (Decap.fsequence (Decap.string ":" ":")
                   (Decap.fsequence module_type
                      (Decap.fsequence (Decap.string ")" ")")
                         (Decap.sequence (Decap.string "->" "->") module_type
                            (fun _  me  _  mt  _  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun _  _  __loc__start__buf  __loc__start__pos
                                  __loc__end__buf  __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 mtyp_loc _loc
                                   (Pmty_functor
                                      ((id_loc mn _loc_mn), mt, me)))))))));
        Decap.fsequence (Decap.string "(" "(")
          (Decap.sequence module_type (Decap.string ")" ")")
             (fun mt  _  _  -> mt));
        Decap.fsequence_position module_kw
          (Decap.fsequence type_kw
             (Decap.sequence of_kw module_expr
                (fun _  me  _  _  __loc__start__buf  __loc__start__pos 
                   __loc__end__buf  __loc__end__pos  ->
                   let _loc =
                     locate2 __loc__start__buf __loc__start__pos
                       __loc__end__buf __loc__end__pos in
                   mtyp_loc _loc (Pmty_typeof me))))]
    let mod_constraint =
      Decap.alternatives'
        [Decap.iter
           (Decap.apply
              (fun t  ->
                 let (_loc_t,t) = t in
                 Decap.apply (fun (tn,ty)  -> (tn, (Pwith_type ty)))
                   (typedef_in_constraint _loc_t)) (locate type_kw));
        Decap.fsequence module_kw
          (Decap.fsequence (locate module_path)
             (Decap.sequence (Decap.char '=' '=')
                (locate extended_module_path)
                (fun _  m2  ->
                   let (_loc_m2,m2) = m2 in
                   fun m1  ->
                     let (_loc_m1,m1) = m1 in
                     fun _  ->
                       let name = id_loc m1 _loc_m1 in
                       (name, (Pwith_module (id_loc m2 _loc_m2))))));
        Decap.fsequence_position type_kw
          (Decap.fsequence (Decap.option [] type_params)
             (Decap.fsequence (locate typeconstr_name)
                (Decap.sequence (Decap.string ":=" ":=") typexpr
                   (fun _  te  tcn  ->
                      let (_loc_tcn,tcn) = tcn in
                      fun tps  _  __loc__start__buf  __loc__start__pos 
                        __loc__end__buf  __loc__end__pos  ->
                        let _loc =
                          locate2 __loc__start__buf __loc__start__pos
                            __loc__end__buf __loc__end__pos in
                        let td =
                          type_declaration _loc (id_loc tcn _loc_tcn) tps []
                            Ptype_abstract Public (Some te) in
                        ((id_loc (Lident tcn) _loc_tcn),
                          (Pwith_typesubst td))))));
        Decap.fsequence module_kw
          (Decap.fsequence (locate module_name)
             (Decap.sequence (Decap.string ":=" ":=")
                (locate extended_module_path)
                (fun _  emp  ->
                   let (_loc_emp,emp) = emp in
                   fun mn  ->
                     let (_loc_mn,mn) = mn in
                     fun _  ->
                       ((id_loc (Lident mn) _loc_mn),
                         (Pwith_modsubst (id_loc emp _loc_emp))))))]
    let _ =
      set_grammar module_type
        (Decap.sequence_position module_type_base
           (Decap.option None
              (Decap.apply (fun x  -> Some x)
                 (Decap.fsequence with_kw
                    (Decap.sequence mod_constraint
                       (Decap.apply List.rev
                          (Decap.fixpoint []
                             (Decap.apply (fun x  l  -> x :: l)
                                (Decap.sequence and_kw mod_constraint
                                   (fun _  m  -> m)))))
                       (fun m  l  _  -> m :: l)))))
           (fun m  l  __loc__start__buf  __loc__start__pos  __loc__end__buf 
              __loc__end__pos  ->
              let _loc =
                locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                  __loc__end__pos in
              match l with
              | None  -> m
              | Some l -> mtyp_loc _loc (Pmty_with (m, l))))
    let structure_item_base =
      Decap.alternatives'
        [Decap.fsequence
           (Decap.regexp ~name:"let" let_re (fun groupe  -> groupe 0))
           (Decap.sequence rec_flag let_binding
              (fun r  l  _  ->
                 match l with
                 | ({ ppat_desc = Ppat_any ; ppat_loc = _ },e)::[] ->
                     pstr_eval e
                 | _ -> Pstr_value (r, l)));
        Decap.fsequence_position external_kw
          (Decap.fsequence (locate value_name)
             (Decap.fsequence (Decap.string ":" ":")
                (Decap.fsequence typexpr
                   (Decap.sequence (Decap.string "=" "=")
                      (Decap.apply List.rev
                         (Decap.fixpoint []
                            (Decap.apply (fun x  l  -> x :: l) string_literal)))
                      (fun _  ls  ty  _  n  ->
                         let (_loc_n,n) = n in
                         fun _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let l = List.length ls in
                           if (l < 1) || (l > 3) then raise Give_up;
                           Pstr_primitive
                             ((id_loc n _loc_n),
                               {
                                 pval_type = ty;
                                 pval_prim = ls;
                                 pval_loc = _loc
                               }))))));
        Decap.apply (fun td  -> Pstr_type td) type_definition;
        Decap.apply (fun ex  -> ex) exception_definition;
        Decap.sequence module_kw
          (Decap.alternatives'
             [Decap.fsequence_position rec_kw
                (Decap.fsequence (locate module_name)
                   (Decap.fsequence (Decap.string ":" ":")
                      (Decap.fsequence module_type
                         (Decap.fsequence (Decap.char '=' '=')
                            (Decap.sequence module_expr
                               (Decap.apply List.rev
                                  (Decap.fixpoint []
                                     (Decap.apply (fun x  l  -> x :: l)
                                        (Decap.fsequence_position and_kw
                                           (Decap.fsequence
                                              (locate module_name)
                                              (Decap.fsequence
                                                 (Decap.string ":" ":")
                                                 (Decap.fsequence module_type
                                                    (Decap.sequence
                                                       (Decap.char '=' '=')
                                                       module_expr
                                                       (fun _  me  mt  _  mn 
                                                          ->
                                                          let (_loc_mn,mn) =
                                                            mn in
                                                          fun _ 
                                                            __loc__start__buf
                                                             __loc__start__pos
                                                             __loc__end__buf 
                                                            __loc__end__pos 
                                                            ->
                                                            let _loc =
                                                              locate2
                                                                __loc__start__buf
                                                                __loc__start__pos
                                                                __loc__end__buf
                                                                __loc__end__pos in
                                                            module_binding
                                                              _loc
                                                              (id_loc mn
                                                                 _loc_mn) mt
                                                              me)))))))))
                               (fun me  ms  _  mt  _  mn  ->
                                  let (_loc_mn,mn) = mn in
                                  fun _  __loc__start__buf  __loc__start__pos
                                     __loc__end__buf  __loc__end__pos  ->
                                    let _loc =
                                      locate2 __loc__start__buf
                                        __loc__start__pos __loc__end__buf
                                        __loc__end__pos in
                                    let m =
                                      module_binding _loc (id_loc mn _loc_mn)
                                        mt me in
                                    Pstr_recmodule (m :: ms)))))));
             Decap.fsequence_position (locate module_name)
               (Decap.fsequence
                  (Decap.apply List.rev
                     (Decap.fixpoint []
                        (Decap.apply (fun x  l  -> x :: l)
                           (Decap.fsequence_position (Decap.string "(" "(")
                              (Decap.fsequence (locate module_name)
                                 (Decap.fsequence (Decap.string ":" ":")
                                    (Decap.sequence module_type
                                       (Decap.string ")" ")")
                                       (fun mt  _  _  mn  ->
                                          let (_loc_mn,mn) = mn in
                                          fun _  __loc__start__buf 
                                            __loc__start__pos 
                                            __loc__end__buf  __loc__end__pos 
                                            ->
                                            let _loc =
                                              locate2 __loc__start__buf
                                                __loc__start__pos
                                                __loc__end__buf
                                                __loc__end__pos in
                                            ((id_loc mn _loc_mn), mt, _loc)))))))))
                  (Decap.fsequence
                     (locate
                        (Decap.option None
                           (Decap.apply (fun x  -> Some x)
                              (Decap.sequence (Decap.string ":" ":")
                                 module_type (fun _  mt  -> mt)))))
                     (Decap.sequence (Decap.string "=" "=")
                        (locate module_expr)
                        (fun _  me  ->
                           let (_loc_me,me) = me in
                           fun mt  ->
                             let (_loc_mt,mt) = mt in
                             fun l  mn  ->
                               let (_loc_mn,mn) = mn in
                               fun __loc__start__buf  __loc__start__pos 
                                 __loc__end__buf  __loc__end__pos  ->
                                 let _loc =
                                   locate2 __loc__start__buf
                                     __loc__start__pos __loc__end__buf
                                     __loc__end__pos in
                                 let me =
                                   match mt with
                                   | None  -> me
                                   | Some mt ->
                                       mexpr_loc (merge2 _loc_mt _loc_me)
                                         (Pmod_constraint (me, mt)) in
                                 let me =
                                   List.fold_left
                                     (fun acc  (mn,mt,_loc)  ->
                                        mexpr_loc (merge2 _loc _loc_me)
                                          (Pmod_functor (mn, mt, acc))) me
                                     (List.rev l) in
                                 let (name,_,me) =
                                   module_binding _loc (id_loc mn _loc_mn)
                                     None me in
                                 Pstr_module (name, me)))));
             Decap.fsequence type_kw
               (Decap.fsequence (locate modtype_name)
                  (Decap.sequence (Decap.string "=" "=") module_type
                     (fun _  mt  mn  ->
                        let (_loc_mn,mn) = mn in
                        fun _  -> Pstr_modtype ((id_loc mn _loc_mn), mt))))])
          (fun _  r  -> r);
        Decap.fsequence open_kw
          (Decap.sequence override_flag (locate module_path)
             (fun o  m  ->
                let (_loc_m,m) = m in
                fun _  -> Pstr_open (o, (id_loc m _loc_m))));
        Decap.sequence include_kw module_expr (fun _  me  -> Pstr_include me);
        Decap.sequence class_kw
          (Decap.alternatives'
             [Decap.apply (fun ctd  -> Pstr_class_type ctd)
                classtype_definition;
             Decap.apply (fun cds  -> Pstr_class cds) class_definition])
          (fun _  r  -> r);
        Decap.apply (fun e  -> pstr_eval e) expression]
    let _ =
      set_grammar structure_item
        (Decap.alternatives'
           [Decap.apply (fun e  -> e) (alternatives extra_structure);
           Decap.fsequence (Decap.char '$' '$')
             (Decap.fsequence (expression_lvl (next_exp App))
                (Decap.sequence (Decap.char '$' '$')
                   (Decap.option None
                      (Decap.apply (fun x  -> Some x)
                         (Decap.string ";;" ";;")))
                   (fun _  _  e  _  -> push_pop_structure e)));
           Decap.sequence (locate structure_item_base)
             (Decap.option None
                (Decap.apply (fun x  -> Some x) (Decap.string ";;" ";;")))
             (fun s  -> let (_loc_s,s) = s in fun _  -> [loc_str _loc_s s])])
    let signature_item_base =
      Decap.alternatives'
        [Decap.fsequence_position val_kw
           (Decap.fsequence (locate value_name)
              (Decap.fsequence (Decap.string ":" ":")
                 (Decap.sequence typexpr post_item_attributes
                    (fun ty  a  _  n  ->
                       let (_loc_n,n) = n in
                       fun _  __loc__start__buf  __loc__start__pos 
                         __loc__end__buf  __loc__end__pos  ->
                         let _loc =
                           locate2 __loc__start__buf __loc__start__pos
                             __loc__end__buf __loc__end__pos in
                         psig_value ~attributes:a _loc (id_loc n _loc_n) ty
                           []))));
        Decap.fsequence_position external_kw
          (Decap.fsequence (locate value_name)
             (Decap.fsequence (Decap.string ":" ":")
                (Decap.fsequence typexpr
                   (Decap.fsequence (Decap.string "=" "=")
                      (Decap.sequence
                         (Decap.apply List.rev
                            (Decap.fixpoint []
                               (Decap.apply (fun x  l  -> x :: l)
                                  string_literal))) post_item_attributes
                         (fun ls  a  _  ty  _  n  ->
                            let (_loc_n,n) = n in
                            fun _  __loc__start__buf  __loc__start__pos 
                              __loc__end__buf  __loc__end__pos  ->
                              let _loc =
                                locate2 __loc__start__buf __loc__start__pos
                                  __loc__end__buf __loc__end__pos in
                              let l = List.length ls in
                              if (l < 1) || (l > 3) then raise Give_up;
                              psig_value ~attributes:a _loc (id_loc n _loc_n)
                                ty ls))))));
        Decap.apply (fun td  -> Psig_type td) type_definition;
        Decap.apply (fun (name,ed,_loc')  -> Psig_exception (name, ed))
          exception_declaration;
        Decap.fsequence_position module_kw
          (Decap.fsequence rec_kw
             (Decap.fsequence (locate module_name)
                (Decap.fsequence (Decap.string ":" ":")
                   (Decap.sequence module_type
                      (Decap.apply List.rev
                         (Decap.fixpoint []
                            (Decap.apply (fun x  l  -> x :: l)
                               (Decap.fsequence_position and_kw
                                  (Decap.fsequence (locate module_name)
                                     (Decap.sequence (Decap.string ":" ":")
                                        module_type
                                        (fun _  mt  mn  ->
                                           let (_loc_mn,mn) = mn in
                                           fun _  __loc__start__buf 
                                             __loc__start__pos 
                                             __loc__end__buf  __loc__end__pos
                                              ->
                                             let _loc =
                                               locate2 __loc__start__buf
                                                 __loc__start__pos
                                                 __loc__end__buf
                                                 __loc__end__pos in
                                             module_declaration _loc
                                               (id_loc mn _loc_mn) mt)))))))
                      (fun mt  ms  _  mn  ->
                         let (_loc_mn,mn) = mn in
                         fun _  _  __loc__start__buf  __loc__start__pos 
                           __loc__end__buf  __loc__end__pos  ->
                           let _loc =
                             locate2 __loc__start__buf __loc__start__pos
                               __loc__end__buf __loc__end__pos in
                           let m =
                             module_declaration _loc (id_loc mn _loc_mn) mt in
                           Psig_recmodule (m :: ms))))));
        Decap.sequence module_kw
          (Decap.alternatives'
             [Decap.fsequence_position (locate module_name)
                (Decap.fsequence
                   (Decap.apply List.rev
                      (Decap.fixpoint []
                         (Decap.apply (fun x  l  -> x :: l)
                            (Decap.fsequence_position (Decap.string "(" "(")
                               (Decap.fsequence (locate module_name)
                                  (Decap.fsequence (Decap.string ":" ":")
                                     (Decap.sequence module_type
                                        (Decap.string ")" ")")
                                        (fun mt  _  _  mn  ->
                                           let (_loc_mn,mn) = mn in
                                           fun _  __loc__start__buf 
                                             __loc__start__pos 
                                             __loc__end__buf  __loc__end__pos
                                              ->
                                             let _loc =
                                               locate2 __loc__start__buf
                                                 __loc__start__pos
                                                 __loc__end__buf
                                                 __loc__end__pos in
                                             ((id_loc mn _loc_mn), mt, _loc)))))))))
                   (Decap.sequence (Decap.string ":" ":")
                      (locate module_type)
                      (fun _  mt  ->
                         let (_loc_mt,mt) = mt in
                         fun l  mn  ->
                           let (_loc_mn,mn) = mn in
                           fun __loc__start__buf  __loc__start__pos 
                             __loc__end__buf  __loc__end__pos  ->
                             let _loc =
                               locate2 __loc__start__buf __loc__start__pos
                                 __loc__end__buf __loc__end__pos in
                             let mt =
                               List.fold_left
                                 (fun acc  (mn,mt,_loc)  ->
                                    mtyp_loc (merge2 _loc _loc_mt)
                                      (Pmty_functor (mn, mt, acc))) mt
                                 (List.rev l) in
                             let (a,b) =
                               module_declaration _loc (id_loc mn _loc_mn) mt in
                             Psig_module (a, b))));
             Decap.fsequence type_kw
               (Decap.sequence (locate modtype_name)
                  (Decap.option None
                     (Decap.apply (fun x  -> Some x)
                        (Decap.sequence (Decap.string "=" "=") module_type
                           (fun _  mt  -> mt))))
                  (fun mn  ->
                     let (_loc_mn,mn) = mn in
                     fun mt  _  ->
                       let mt =
                         match mt with
                         | None  -> Pmodtype_abstract
                         | Some mt -> Pmodtype_manifest mt in
                       Psig_modtype ((id_loc mn _loc_mn), mt)))])
          (fun _  r  -> r);
        Decap.fsequence open_kw
          (Decap.sequence override_flag (locate module_path)
             (fun o  m  ->
                let (_loc_m,m) = m in
                fun _  -> Psig_open (o, (id_loc m _loc_m))));
        Decap.sequence include_kw module_type (fun _  me  -> Psig_include me);
        Decap.sequence class_kw
          (Decap.alternatives'
             [Decap.apply (fun ctd  -> Psig_class_type ctd)
                classtype_definition;
             Decap.apply (fun cs  -> Psig_class cs) class_specification])
          (fun _  r  -> r)]
    let _ =
      set_grammar signature_item
        (Decap.alternatives'
           [Decap.apply (fun e  -> e) (alternatives extra_signature);
           Decap.fsequence (Decap.char '$' '$')
             (Decap.sequence (expression_lvl (next_exp App))
                (Decap.char '$' '$') (fun e  _  _  -> push_pop_signature e));
           Decap.sequence_position signature_item_base
             (Decap.option None
                (Decap.apply (fun x  -> Some x) (Decap.string ";;" ";;")))
             (fun s  _  __loc__start__buf  __loc__start__pos  __loc__end__buf
                 __loc__end__pos  ->
                let _loc =
                  locate2 __loc__start__buf __loc__start__pos __loc__end__buf
                    __loc__end__pos in
                [loc_sig _loc s])])
    exception Top_Exit
    let top_phrase =
      Decap.alternatives'
        [Decap.fsequence
           (Decap.option None
              (Decap.apply (fun x  -> Some x) (Decap.char ';' ';')))
           (Decap.sequence
              (Decap.sequence
                 (Decap.apply_position
                    (fun s  __loc__start__buf  __loc__start__pos 
                       __loc__end__buf  __loc__end__pos  ->
                       let _loc =
                         locate2 __loc__start__buf __loc__start__pos
                           __loc__end__buf __loc__end__pos in
                       loc_str _loc s) structure_item_base)
                 (Decap.fixpoint []
                    (Decap.apply (fun x  l  -> x :: l)
                       (Decap.apply_position
                          (fun s  __loc__start__buf  __loc__start__pos 
                             __loc__end__buf  __loc__end__pos  ->
                             let _loc =
                               locate2 __loc__start__buf __loc__start__pos
                                 __loc__end__buf __loc__end__pos in
                             loc_str _loc s) structure_item_base)))
                 (fun x  l  -> x :: (List.rev l))) double_semi_col
              (fun l  _  _  -> Ptop_def l));
        Decap.sequence
          (Decap.option None
             (Decap.apply (fun x  -> Some x) (Decap.char ';' ';')))
          (Decap.eof ()) (fun _  _  -> raise Top_Exit)]
  end
