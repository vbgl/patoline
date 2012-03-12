(** La "classe" de documents par defaut. *)

open Util
open Binary
open Constants
open Fonts
open Fonts.FTypes
open Drivers

(** Pour choisir la police, et d'autres paramètres, on a un
   environnement. On peut tout modifier de manière uniforme sur tout
   le document à partir de n'importe où (voir le type content, plus
   bas, pour les scopes) *)

type fontAlternative = Regular | Bold | Caps | Demi
 
(* Italic is second *)
type fontFamily = (fontAlternative * (font Lazy.t * font Lazy.t)) list

let lmroman =
  [ Regular, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmroman10-regular.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmroman10-italic.otf"));
    Bold, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmroman10-bold.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmroman10-bolditalic.otf"));
    Caps, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmromancaps10-regular.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmromancaps10-oblique.otf"));
    Demi, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmromandemi10-regular.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmromandemi10-oblique.otf"));
  ]

let lmmono =
  [ Regular, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmmonolt10-regular.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmmonolt10-oblique.otf"));
    Bold, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmmonolt10-bold.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/lmmonolt10-boldoblique.otf"));
    Caps, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmmonocaps10-regular.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmmonocaps10-oblique.otf"));
    Demi, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmmonoltcond10-regular.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/lmmonoltcond10-oblique.otf"));
  ]

(*Alegreya raises : Opentype.Table_not_found
let alegreya =
  [ Regular, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/Alegreya-Regular.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/Alegreya-Italic.otf"));
    Bold, (
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/Alegreya-Bold.otf"),
       Lazy.lazy_from_fun (fun () -> 
	 loadFont "Otf/Alegreya-BoldItalic.otf"));
    Caps, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/AlegreyaSC-Regular.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/AlegreyaSC-Italic.otf"));
    Demi, (
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/Alegreya-Black.otf"),
      Lazy.lazy_from_fun (fun () -> 
	loadFont "Otf/Alegreya-BlackItalic.otf"));
  ]*)

let selectFont fam alt it =
  try
    let r, i = List.assoc alt fam in
    Lazy.force (if it then i else r)
  with Not_found ->
    /* FIXME: keep the font name and print a better message */
    Printf.fprintf stderr "Font not found in family.\n"; 
    exit 1

type environment={
  mutable fontFamily:fontFamily;
  mutable fontItalic:bool;
  mutable fontAlternative:fontAlternative;
  mutable fontFeatures:Fonts.FTypes.features list;
  mutable font:font;
  mutable size:float;
  mutable par_indent:float;
  mutable stdGlue:box;
  mutable hyphenate:string->(string*string) array;
  mutable substitutions:glyph_id list -> glyph_id list;
  mutable positioning:glyph_ids list -> glyph_ids list;
}

let defaultFam= lmroman
let defaultMono= lmmono
let defaultEnv=
  let f=selectFont lmroman Regular false in
  let fsize=5. in
    {
      fontFamily=lmroman;
      fontItalic=false;
      fontAlternative=Regular;
      fontFeatures= [ StandardLigatures ];
      font=f;
      substitutions=
        (fun glyphs -> List.fold_left apply glyphs (
           Fonts.select_features f [ StandardLigatures ]
         ));
      positioning=positioning f;
      size=4.;
      par_indent = 4.0 *. phi;
      stdGlue=Glue { drawing_min_width= 2.*. fsize/.9.;
                     drawing_max_width= fsize/.2.;
                     drawing_y0=0.; drawing_y1=0.;
                     drawing_nominal_width= fsize/.3.;
                     drawing_contents=(fun _->[]);
                     drawing_badness=knuth_h_badness (fsize/.3.) };
      hyphenate=(
        fun str->
          let hyphenation_dict=
            let i=open_in "dict_en" in
            let inp=input_value i in
              close_in i;
              inp
          in
          let hyphenated=Hyphenate.hyphenate hyphenation_dict str in
          let pos=Array.make (List.length hyphenated-1) ("","") in
          let rec hyph l i cur=match l with
              []->()
            | h::s->(
                pos.(i)<-(cur^"-", List.fold_left (^) "" l);
                hyph s (i+1) (cur^h)
              )
          in
            match hyphenated with
                []->[||]
              | h::s->(hyph s 0 h; pos)
      );
    }


(* Type du contenu. B est une boîte quelconque. Les espaces dans T
   seront transformés en la boîte stdGlue de l'environnement, qui
   n'est pas nécessairement une GlueBox *)
type content=
    B of (environment->box)
  | T of string
  | FileRef of (string*int*int)
  | Scoped of (environment->environment)*(content list)



(****************************************************************)



(* Le jeu est de construire la structure de document suivante :
   C'est un arbre, avec du contenu texte à chaque nœud. *)

type node={
  name:string;
  displayname:content list;
  children:tree IntMap.t;
  mutable tree_paragraph:int;
}
and paragraph={
  par_contents:content list;
  par_env:environment;
  parameters:box array array -> drawingBox array -> parameters -> line -> parameters;
  completeLine:box array array -> line -> bool -> line list
}
and tree=
    Node of node
  | Paragraph of paragraph


let empty={ name=""; displayname = []; children=IntMap.empty; tree_paragraph= (-1) }

(* La structure actuelle *)
let str=ref (Node empty)
(* Le chemin vers le noeud courant *)
let cur=ref []

(* Liste des figures. La définition des drawingBox est dans Util.ml,
   c'est essentiellement le type du driver avec un cadre autour *)
let figures:drawingBox list ref=ref []

(* Sortie en dot de la structure du document *)
let doc_graph out t0=
  Printf.fprintf out "digraph {\n";
  let rec do_it path t=
    Printf.fprintf out "%s [label=\"%s\"];\n" path t.name;
    List.iter (fun (i,x)->match x with
                   Paragraph _-> ()
                 | Node n->(
                     let p=path^"_"^(string_of_int i) in
                       Printf.fprintf out "%s -> %s;\n" path p;
                       do_it p n)) (IntMap.bindings t.children)
  in
    (match t0 with
         Node t->do_it "x0" t
       | _->());
    Printf.fprintf out "}\n"


let next_key t=try fst (IntMap.max_binding t)+1 with Not_found -> 0

(* Exemple de manipulation de la structure : faire un nouveau paragraphe *)
let newPar ?(environment=defaultEnv) complete parameters par=
  let para=Paragraph {par_contents=par; par_env=environment; parameters=parameters; completeLine=complete } in
  let rec newPar tree path=
    match path with
        []->(match tree with
                 Node t->Node { t with children=IntMap.add (next_key t.children) para t.children }
               | _ -> Node { empty with children=IntMap.add 1 tree (IntMap.add 2 para IntMap.empty) })
      | h::s->
          (match tree with
               Node t->(let t'=try IntMap.find h t.children with _->Node empty in
                          Node { t with children=IntMap.add h (newPar t' s) t.children })

             | _ -> Node { empty with children=IntMap.add 1 tree (IntMap.add 2 (newPar (Node empty) s) IntMap.empty) })
  in
    str:=newPar !str !cur

(* Remonter d'un niveau dans l'arbre, par rapport au noeud courant *)
let up ()=
  let rec up=function
      []->[]
    | [h]->[]
    | h::s-> h::up s
  in
    cur:=up !cur

let string_of_contents l =
  let s = ref "" in
  List.iter (function
    T str -> 
      if !s = "" then s:= str else s:= !s ^" " ^str
  | _ -> ()) l;
  !s

let newStruct ?label displayname =
  let name = match label with
      None -> string_of_contents displayname
    | Some s -> s
  in
  let para=Node { empty with name=name; displayname = displayname } in
  let rec newStruct tree path=
    match path with
        []->(match tree with
                 Node t->(
                   let next=next_key t.children in
                     cur:= !cur @ [next];
                     Node { t with children=IntMap.add next para t.children }
                 )
               | _ -> Node { empty with children=IntMap.add 1 tree (IntMap.add 2 para IntMap.empty) })
      | h::s->
          (match tree with
               Node t->(let t'=try IntMap.find h t.children with _->Node empty in
                          Node { t with children=IntMap.add h (newStruct t' s) t.children })

             | _ -> Node { empty with children=IntMap.add 1 tree (IntMap.add 2 (newStruct (Node empty) s) IntMap.empty) })
  in
    str:=newStruct !str !cur

let title ?label displayname =
  let name = match label with
      None -> string_of_contents displayname
    | Some s -> s
  in
  match !str with
      Paragraph _->str:= Node { name=name; displayname = displayname; 
				children=IntMap.singleton 1 !str; tree_paragraph=0 }
    | Node n -> str:=Node { n with name=name; displayname = displayname }


(****************************************************************)


(* Quelques Exemples d'environnement *)

let updateFont env font =
     { env with
       font=font;
       substitutions=
         (fun glyphs -> List.fold_left apply glyphs (
           Fonts.select_features font env.fontFeatures
          ));
       positioning=positioning font }
  
(* Changer de font dans un scope, ignore la famille, attention, à éviter en direct *)
let font f t=
  let font=loadFont f in
    [Scoped ((fun env-> updateFont env font), t)]

let envItalic b env =
  let font = selectFont env.fontFamily env.fontAlternative b in
  let env = { env with fontItalic = b } in
  updateFont env font
      
let italic t =
  [Scoped(envItalic true, t)]

module Italic = struct
  let do_begin_Italic () = ()
  let do_end_Italic () = ()
  let defaultEnv = envItalic true defaultEnv
end

module Env_Italic = Italic

let notItalic t =
  [Scoped (envItalic false, t)]

let toggleItalic t =
  [Scoped ((fun env -> envItalic (not env.fontItalic) env), t)]
 
let envAlternative features alt env =
  let font = selectFont env.fontFamily alt env.fontItalic in
  let env = { env with fontAlternative = alt } in
  updateFont env font
 
let alternative ?features alt t =
  [Scoped ((fun env -> 
    let features = match features with
	None -> env.fontFeatures
      | Some f -> f
    in
    envAlternative features alt env), t)]

let envFamily fam env =
  let font = selectFont fam env.fontAlternative env.fontItalic in
  let env = { env with fontFamily = fam } in
  updateFont env font

let family fam t =
  [Scoped ((fun env -> envFamily fam env), t)]

(* Changer de taille dans un scope *)
let size fsize t=
  Scoped ((fun env ->
             { env with
                 size=fsize;
                 stdGlue=Glue { drawing_min_width= 2.*. fsize/.9.;
                                drawing_max_width= fsize/.2.;
                                drawing_y0=0.;drawing_y1=0.;
                                drawing_nominal_width= fsize/.3.;
                                drawing_contents = (fun _->[]);
                                drawing_badness=knuth_h_badness (fsize/.3.) }}), t)
let glues t=
  Scoped ((fun env ->
             match env.stdGlue with
                 Glue g ->(
                   let rec select_glue=function
                       []->Glue g
                     | Alternative a::_->(
                         let gl=
                           (glyphCache env.font { empty_glyph with glyph_index=a.(Random.int (Array.length a-1)) })
                         in
                           Glue { g with
                                    drawing_contents=(
                                      fun w->[
                                        Drivers.Glyph { gl with
                                                          glyph_y=0.;
                                                          glyph_x=
                                            (w-.env.size*.Fonts.glyphWidth gl.glyph/.1000.)/.2.;
                                                          glyph_size=env.size }
                                      ]);
                                    drawing_min_width=(
                                      g.drawing_min_width+.
                                        env.size*.Fonts.glyphWidth gl.glyph/.1000.);
                                    drawing_nominal_width=(
                                      g.drawing_nominal_width+.
                                        env.size*.Fonts.glyphWidth gl.glyph/.1000.);
                                    drawing_max_width=(
                                      g.drawing_max_width+.
                                        env.size*.Fonts.glyphWidth gl.glyph/.1000.);

                                })
                       | _::s-> select_glue s
                   in
                     { env with stdGlue=select_glue (select_features env.font [Ornaments]) }
                 )
               |_->env
          ), t)



(* Rajouter une liste de features, voir Fonts.FTypes pour savoir ce
   qui existe *)
let features f t=
  Scoped ((fun env->
             { env with substitutions=
                 (fun glyphs -> List.fold_left apply glyphs
                    (Fonts.select_features env.font f))}), t)

(****************************************************************)

(* Partie compliquée : il faut comprendre ce que fait l'optimiseur
   pour toucher à ça, ou apprendre en touchant ça *)





let parameters paragraphs figures last_parameters line=
  let mes=150. in
  { lead=5.;
    measure= mes;
    lines_by_page=if line.page_height <= 0 then 45 else last_parameters.lines_by_page;
    left_margin=(
      let space=(fst a4-.mes)/.2. in
        if line.isFigure then (
          space+.(mes -. (figures.(line.lastFigure).drawing_max_width
                          +. figures.(line.lastFigure).drawing_min_width)/.2.)/.2.
        ) else space
    );
    local_optimization=0;
    min_page_diff=0;
    min_height_before=max 1 last_parameters.min_height_after;
    min_height_after=1;
    allow_widows=true;
    allow_orphans=true
  }

(* Centre les lignes d'un paragraphe. Il faut un optimiseur différent ici *)
let center paragraphs figures last_parameters l=
  let param=parameters paragraphs figures last_parameters l in
  let b=l.nom_width in
    if param.measure >= b then
      { param with measure=b; left_margin=param.left_margin +. (param.measure-.b)/.2. }
    else
      param

(****************************************************************)

(* Fonctions auxiliaires qui produisent un document optimisable à
   partir de l'arbre *)


let structNum path name=
  let n=match path with
      h::s->List.fold_left (fun x y -> x^"."^(string_of_int (y+1))) (string_of_int (h+1)) s
    | []->"0"
  in
  if List.length path <= 2 then
    [Scoped ((fun env->{(envAlternative (OldStyleFigures::env.fontFeatures) Caps env) with
      size=(if List.length path = 1 then sqrt phi else sqrt (sqrt phi))*.env.size
    }), (T n::B (fun env -> env.stdGlue)::name))]
  else
    [Scoped ((fun env-> envAlternative (OldStyleFigures::env.fontFeatures) Caps env),
	     (T n::B (fun env -> env.stdGlue)::name))]


let is_space c=c=' ' || c='\n' || c='\t'
let sources=ref StrMap.empty

let rec boxify env =function
[]->[]
  | (B b)::s->(b env)::(boxify env s)
  | (T t)::s->(
    let rec cut_str i0 i result=
      if i>=String.length t then (
        if i0<>i then (
          if result<>[] then
            result @ (env.stdGlue :: (glyph_of_string env.substitutions env.positioning env.font env.size
                                        (String.sub t i0 (i-i0))))
          else
            glyph_of_string env.substitutions env.positioning env.font env.size (String.sub t i0 (i-i0))
        ) else result
      ) else (
        if is_space t.[i] then
          cut_str (i+1) (i+1) (
            if i0<>i then (
              if result<>[] then
                result @ (env.stdGlue :: (glyph_of_string env.substitutions env.positioning env.font env.size
                                            (String.sub t i0 (i-i0))))
              else
                glyph_of_string env.substitutions env.positioning env.font env.size (String.sub t i0 (i-i0))
            ) else result
          )
        else (
          cut_str i0 (i+1) result
        )
      )
    in
    let c=cut_str 0 0 [] in
    c @ (boxify env s)
  )
  | FileRef (file,off,size)::s -> (
    let i=try 
	    StrMap.find file !sources 
      with _-> (let i=open_in file in sources:= StrMap.add file i !sources; i) 
    in
    let buf=String.create size in
    let _=seek_in i off; input i buf 0 size in
    boxify env (T buf::s)
  )
  | Scoped (env', p)::s->(
    let c=(boxify (env' env) p) in
    c@(boxify env s)
  )

let flatten env0 str=

  let paragraphs=ref [] in
  let param=ref [] in
  let compl=ref [] in
  let n=ref 0 in


  let add_paragraph p=
    paragraphs:=(Array.of_list (boxify p.par_env p.par_contents))::(!paragraphs);
    compl:=(p.completeLine)::(!compl);
    param:=(p.parameters)::(!param);
    incr n;
  in

  let rec flatten env path tree=
    match tree with
        Paragraph p -> add_paragraph p
      | Node s-> (
          s.tree_paragraph <- !n;
          if path<>[] then (
            add_paragraph ({ par_contents=structNum path s.displayname;
                             par_env=env;
                             parameters=
                               (fun paragraphs figures last_parameters line ->
                                  { (parameters paragraphs figures last_parameters line) with
                                      min_height_before=2; min_height_after=2 });
                             completeLine=Parameters.normal (fst a4) });
          ) else if s.name<>"" then (
            add_paragraph {par_contents=[size 10. [T (s.name)] ];
                           par_env=env;
                           parameters=(
                             fun paragraphs figures last_parameters line ->
                               let c=center paragraphs figures last_parameters line in
                                 { c with min_height_after=max 4 c.min_height_after });
                           completeLine=Parameters.normal (fst a4) }
          );
          let rec flat_children num indent= function
              []->()
            | (_, (Paragraph p as tr))::s->(
                flatten env path (
                  let g=B (fun env->Glue { drawing_min_width= env.par_indent;
                                           drawing_max_width= env.par_indent;
                                           drawing_y0=0.;drawing_y1=0.;
                                           drawing_nominal_width= env.par_indent;
                                           drawing_contents=(fun _->[]);
                                           drawing_badness=fun _-> 0. })
                  in
                    if indent && p.par_env.par_indent <> 0.0 then (
                      Paragraph { p with par_contents=g::p.par_contents }
                    ) else tr);
                flat_children num true s
              )
            | (_, (Node _ as tr))::s->(
                flatten env (path@[num]) tr;
                flat_children (num+1) false s
              )
          in
            flat_children 0 false (IntMap.bindings s.children)
        )
  in
    flatten env0 [] str;
    (Array.of_list (List.rev !param),
     Array.of_list (List.rev !compl),
     Array.of_list (List.rev !paragraphs))


let rec make_struct positions tree=
  match tree with
      Paragraph p ->
          { Drivers.name="";
	    Drivers.displayname=[];
            Drivers.page=0;
            Drivers.struct_x=0.;
            Drivers.struct_y=0.;
            Drivers.substructures=[||] }
    | Node s-> (
        let (p,x,y)=positions.(s.tree_paragraph) in
        let rec make=function
            []->[]
          | (_,Paragraph _) :: s->make s
          | (_,Node u)::s -> (make_struct positions (Node u))::(make s)
        in
        let a=Array.of_list (make (IntMap.bindings s.children)) in
          { Drivers.name=s.name;
	    Drivers.displayname=[] (* FIXME boxify ?env [T s.name] *);
            Drivers.page=p;
            Drivers.struct_x=x;
            Drivers.struct_y=y;
            Drivers.substructures=a }
      )
