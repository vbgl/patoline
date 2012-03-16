open OutputCommon
open Binary
open Constants
open CamomileLibrary
open Util
open Fonts.FTypes


let rec print_graph file paragraphs graph path=
  let f=open_out file in
  let rec make_path p1 p2=function
      [] | [_]->false
    | (_,h)::(a,h')::s->(p1=h && p2=h') || make_path p1 p2 ((a,h')::s)
  in
    Printf.fprintf f "digraph {\n";
    LineMap.iter (fun k (b,_,a,_,_)->
                    Printf.fprintf f "node_%d_%s_%s_%s [label=\"%d : %d, %d, %d\"];\n"
                      k.paragraph (if k.lineStart>=0 then string_of_int k.lineStart else "x")
                      (if k.lineEnd>=0 then string_of_int k.lineEnd else "x")
                      (if k.hyphenEnd>=0 then string_of_int k.hyphenEnd else "x")

                      k.paragraph k.lineStart k.lineEnd k.hyphenEnd;

                    Printf.fprintf f "node_%d_%s_%s_%s -> node_%d_%s_%s_%s[color=%s, label=\"%F\"]\n"
                      a.paragraph (if a.lineStart>=0 then string_of_int a.lineStart else "x")
                      (if a.lineEnd>=0 then string_of_int a.lineEnd else "x")
                      (if a.hyphenEnd>=0 then string_of_int a.hyphenEnd else "x")

                      k.paragraph (if k.lineStart>=0 then string_of_int k.lineStart else "x")
                      (if k.lineEnd>=0 then string_of_int k.lineEnd else "x")
                      (if k.hyphenEnd>=0 then string_of_int k.hyphenEnd else "x")

                      (if k.lastFigure<>a.lastFigure then "green" else
                         if make_path a k path then "blue" else "black")
                      b(*k.height-a.height*)
                 ) graph;
    Printf.fprintf f "};\n";
    close_out f

let print_simple_graph file paragraphs graph=
  print_graph file paragraphs (
    LineMap.fold (fun k->LineMap.add { k with height=0.; page=0 }) LineMap.empty graph
  ) []


let is_last paragraph j=
  let rec is_last i=
    (i>=Array.length paragraph ||
       match paragraph.(i) with
           Glue _->is_last (i+1)
         | _->false)
  in
    is_last (j+1)

module type User=sig
  type t
  val compare:t->t->int
  val citation:int->t
end


module Make=functor (User:User)->struct
  module UMap=New_map.Make(User)

  let haut=ref (Array.make 100 Empty)
  let max_haut=ref 0
  let bas=ref (Array.make 100 Empty)
  let max_bas=ref 0
  let writeBox arr i b=
    if i>=Array.length !arr then (
      let tmp= !arr in
      arr:=Array.make ((Array.length !arr)*2) Empty;
      for j=0 to Array.length tmp-1 do
        !arr.(j)<-tmp.(j)
      done);
    !arr.(i)<-b

  let readBox arr i= !arr.(i)

  let typeset ~completeLine ~figures ~figure_parameters ~parameters ~badness paragraphs=

    let collide line_haut params_i comp_i line_bas params_j comp_j=

      max_haut:=
        if line_haut.isFigure then
          (let fig=figures.(line_haut.lastFigure) in
             writeBox haut 0 (Drawing { fig with drawing_y1=0.; drawing_y0=fig.drawing_y0-.fig.drawing_y1 }); 1)
        else
          fold_left_line paragraphs (fun i b->writeBox haut i b; i+1) 0 line_haut;

      max_bas:=
        if line_bas.isFigure then
          (let fig=figures.(line_bas.lastFigure) in
             writeBox bas 0 (Drawing { fig with drawing_y1=0.; drawing_y0=fig.drawing_y0-.fig.drawing_y1 }); 1)
        else
          fold_left_line paragraphs (fun i b->writeBox bas i b; i+1) 0 line_bas;

      let xi=ref params_i.left_margin in
      let xj=ref params_j.left_margin in
      let rec collide i j max_col=
        let box_i=readBox haut i in
        let box_j=readBox bas j in
        (* let _=Graphics.wait_next_event [Graphics.Key_pressed] in *)
        let wi=box_width comp_i box_i in
        let wj=box_width comp_j box_j in
          if !xi +.wi < !xj+. wj && i < !max_haut then (
            let yi=lower_y box_i wi in
            let yj=if !xi+.wi < !xj then -.infinity else
              if upper_y box_j wj > -.infinity then upper_y box_j wj else 0.
            in
              (* let x0=if !xi+.wi < !xj then !xi else max !xi !xj in *)
              (* let w0= !xi +. wi -. x0 in *)
              (* Graphics.draw_rect (round (mm*. x0)) (yj0 + round (mm*. yj)) *)
              (*   (round (mm*. (w0))) (yi0 -yj0 + round (mm*. (yi-.yj))); *)
              xi:= !xi+.wi;
              collide (i+1) j (min max_col (yi-.yj))
          ) else if j < !max_bas then (
            let yi=if !xj +. wj < !xi then infinity else
              if lower_y box_i wi < infinity then lower_y box_i wi else 0. in

            let yj=upper_y box_j wj in
              (* let x0=if !xj+.wj < !xi then !xj else max !xi !xj in *)
              (* let w0= !xj +. wj -. x0 in *)
              (* Graphics.draw_rect (round (mm*. x0)) (yj0 + round (mm*. yj)) *)
              (*   (round (mm*. w0)) (yi0 -yj0 + round (mm*. (yi-.yj))); *)
              xj:= !xj+.wj;
              collide i (j+1) (min max_col (yi-.yj))
          ) else max_col
      in
        collide 0 0 infinity
    in




    let log=ref [] in

    let rec break allow_impossible todo demerits=
      (* A chaque etape, todo contient le dernier morceau de chemin qu'on a construit dans demerits *)
      if LineMap.is_empty todo then demerits else (
        let node,(lastBadness,lastParameters,lastFigures,lastUser)=LineMap.min_binding todo in

        let todo'=ref (LineMap.remove node todo) in
          if node.paragraph >= Array.length paragraphs then break false !todo' demerits else
            (
              (* On commence par chercher la première vraie boite après node *)
              let demerits'=ref demerits in
              let register node nextNode badness next_params nextFigures=
                let reallyAdd ()=
                  let nextUser=Util.fold_left_line paragraphs (fun u box->match box with
                                                                   User uu->UMap.add uu nextNode u
                                                                 | _->u) lastUser nextNode
                  in

                  todo':=LineMap.add nextNode (badness,next_params,nextFigures,nextUser) !todo';
                  demerits':=LineMap.add nextNode (badness,next_params,node,nextFigures,nextUser) !demerits'
                in
                  try
                    let bad,_,_,_,_=LineMap.find nextNode !demerits' in
                      if bad >= badness then reallyAdd ()
                  with
                      Not_found->reallyAdd ()
              in
              let i,pi=(if node.hyphenEnd<0 && node.lineEnd+1>=Array.length paragraphs.(node.paragraph) then
                          (0,node.paragraph+1)
                        else if node.hyphenEnd<0 then (node.lineEnd+1, node.paragraph) else (node.lineEnd, node.paragraph))
              in
                (* Y a-t-il encore des boites dans ce paragraphe ? *)
                if pi<>node.paragraph then (
                  if node.lastFigure < Array.length figures-1 then (
                    try
                      let _=UMap.find (User.citation (node.lastFigure+1)) lastUser in
                      let fig=figures.(node.lastFigure+1) in
                      let vspace,_=line_height paragraphs node in
                      let h=ceil (abs_float vspace) in
                      let fig_height=(ceil (fig.drawing_y1-.fig.drawing_y0)) in
                        for h'=0 to 0 do
                          if node.height+.h +. float_of_int h'+.fig_height <= lastParameters.page_height then
                            let nextNode={
                              paragraph=pi; lastFigure=node.lastFigure+1; isFigure=true;
                              hyphenStart= -1; hyphenEnd= -1;
                              height=node.height+.h+. float_of_int h';
                              lineStart= -1; lineEnd= -1; paragraph_height= -1;
                              page_line=node.page_line+1; page=node.page;
                              min_width=fig.drawing_min_width;nom_width=fig.drawing_min_width;max_width=fig.drawing_min_width }
                            in
                            let params=figure_parameters.(node.lastFigure+1) paragraphs figures lastParameters lastFigures lastUser nextNode in
                              register node nextNode
                                (lastBadness+.badness
                                   node !haut 0 lastParameters 0.
                                   nextNode !bas 0 params 0.)
                                params
                                (IntMap.add nextNode.lastFigure nextNode lastFigures)
                        done
                    with
                        Not_found -> ()
                  )
                );

                if pi>=Array.length paragraphs then (
                  let endNode={paragraph=pi;lastFigure=node.lastFigure;hyphenStart= -1;hyphenEnd= -1; isFigure=false;
                               height=node.height; lineStart= -1; lineEnd= -1; paragraph_height= -1;
                               page_line=node.page_line+1; page=node.page; min_width=0.;nom_width=0.;max_width=0. } in
                    register node endNode lastBadness lastParameters lastFigures;
                ) else (
                  let page0,h0=if node.height>=lastParameters.page_height then (node.page+1,0.) else (node.page, node.height) in
                  let r_nextNode={
                    paragraph=pi; lastFigure=node.lastFigure; isFigure=false;
                    hyphenStart= node.hyphenEnd; hyphenEnd= (-1);
                    height = h0;
                    lineStart= i; lineEnd= i;
                    paragraph_height=if i=0 then 0 else node.paragraph_height+1;
                    page_line=if page0=node.page then node.page_line+1 else 0;
                    page=page0;
                    min_width=0.;nom_width=0.;max_width=0. }
                  in

                  let r_params=ref lastParameters in
                  let local_opt=ref [] in
                  let extreme_solutions=ref [] in
                  let solutions_exist=ref false in
                  let rec fix page height=
                    if height>=(!r_params).page_height then
                      fix (page+1) 0.
                    else (
                      r_nextNode.height<-height;
                      r_nextNode.page<-page;
                      r_nextNode.page_line<-if page=node.page then node.page_line+1 else 0;

                      let make_next_node nextNode=
                        r_params:=parameters.(pi) paragraphs figures lastParameters lastFigures lastUser nextNode;
                        let comp0=ref 0. in
                        let comp1=comp paragraphs !r_params.measure pi i node.hyphenEnd nextNode.lineEnd nextNode.hyphenEnd in
                        let height'=
                          if page=node.page then (
                            let rec v_distance node0 parameters=
                              comp0:=comp paragraphs parameters.measure node0.paragraph node0.lineStart
                                node0.hyphenStart node0.lineEnd node0.hyphenEnd;
                              if node0.isFigure then (
                                let dist=collide node0 parameters !comp0 nextNode !r_params comp1 in
                                  if dist < infinity then node0.height+. (ceil (-.dist)) else (
                                    try
                                      let ((_,_,ant,_,_))=LineMap.find node0 !demerits' in
                                      let ((_,params,_,_,_))=LineMap.find ant !demerits' in
                                        v_distance ant params
                                    with
                                        Not_found -> node0.height
                                  )
                              ) else (
                                let dist=collide node0 parameters !comp0 nextNode !r_params comp1 in
                                  node0.height+. (ceil (-.dist))
                              )
                            in
                              v_distance node lastParameters
                          ) else (
                            ceil (snd (line_height paragraphs nextNode))
                          )
                        in
                          if height>=height'
                            && (page,height) >= (node.page + !r_params.min_page_diff,
                                                 node.height +. !r_params.min_height_before)
                          then (
                            let allow_orphan=
                              page=node.page || node.paragraph_height>0 in
                            let allow_widow=
                              page=node.page || (not (is_last paragraphs.(node.paragraph) nextNode.lineEnd)) in

                              if not allow_orphan && allow_widow then (
                                if allow_impossible then (
                                  log:=(Orphan node)::(!log);
                                  let _,_,last_ant,_,_=LineMap.find node !demerits' in
                                  let ant_bad, ant_par, ant_ant,ant_fig,ant_user=LineMap.find last_ant !demerits' in
                                    extreme_solutions:=(ant_ant,last_ant,ant_bad, { ant_par with page_height=node.height },
                                                        ant_fig,ant_user)::(!extreme_solutions);
                                    solutions_exist:=true;
                                )
                              ) else if not allow_widow && allow_orphan then (
                                if allow_impossible then (
                                  log:=(Widow nextNode)::(!log);
                                  let _,_, last_ant,_,_=LineMap.find node !demerits' in
                                  let ant_bad, ant_par, ant_ant, ant_fig,ant_user=LineMap.find last_ant !demerits' in
                                    extreme_solutions:=(ant_ant,last_ant,ant_bad, { ant_par with page_height=node.height },
                                                        ant_fig,ant_user)::(!extreme_solutions);
                                    solutions_exist:=true;
                                )
                              )
                              else if nextNode.min_width > (!r_params).measure then (
                                log:=(Overfull_line nextNode)::(!log);
                                solutions_exist:=true;
                                let nextUser=lastUser in
                                let bad=(lastBadness+.
                                           badness node !haut !max_haut lastParameters !comp0
                                           nextNode !bas !max_bas !r_params comp1) in
                                  local_opt:=(node,nextNode,bad,!r_params,lastFigures,nextUser)::(!local_opt);
                                  (* register node nextNode bad (!r_params) *)
                              ) else (
                                solutions_exist:=true;
                                let nextUser=lastUser in
                                let bad=(lastBadness+.
                                           badness node !haut !max_haut lastParameters !comp0
                                           nextNode !bas !max_bas !r_params comp1) in
                                  local_opt:=(node,nextNode,bad,!r_params,lastFigures,nextUser)::(!local_opt);
                                  (* register node nextNode bad (!r_params) *)
                              )
                          )
                      in
                        List.iter make_next_node (completeLine.(pi) paragraphs figures lastFigures lastUser r_nextNode allow_impossible);
                        let next_h=lastParameters.next_acceptable_height node height in
                        if (not !solutions_exist) && page<=node.page+1 then fix page (if next_h=node.height then node.height+.1. else next_h);
                    )
                  in
                    (try
                       fix node.page (lastParameters.next_acceptable_height node node.height);

                       if !local_opt=[] && !extreme_solutions<>[] then (
                         List.iter (fun (node,nextNode,bad,params,fig,user)->
                                      let a,_,_=LineMap.split nextNode !demerits' in
                                      let b,_,_=LineMap.split nextNode !todo' in
                                        demerits':=a;
                                        todo':=b
                                   ) !extreme_solutions;
                         local_opt:= !extreme_solutions
                       );

                       if !local_opt <> [] then (
                         let l0=List.sort (fun (_,_,b0,_,_,_) (_,_,b1,_,_,_)->compare b0 b1) !local_opt in
                         let deg=List.fold_left (fun m (_,_,_,p,_,_)->max m p.local_optimization) 0 l0 in
                         let rec register_list i l=
                           if i>0 || deg<=0 then (
                             match l with
                                 []->()
                               | (node,nextNode,bad,params,fig,user)::s->(
                                   register node nextNode bad params fig;
                                   register_list (i-1) s
                                 )
                           )
                         in
                           register_list deg l0
                       )
                     with
                         Not_found->()
                    )
                );
                break false !todo' !demerits'
            )
      )
    in
    let first_line={ paragraph=0; lineStart= -1; lineEnd= -1; hyphenStart= -1; hyphenEnd= -1; isFigure=false;
                     lastFigure=(-1); height= 0.;paragraph_height= -1; page_line=0; page=0;
                     min_width=0.;nom_width=0.;max_width=0. } in
    let first_parameters=parameters.(0) paragraphs figures default_params IntMap.empty UMap.empty first_line in

    let todo0=LineMap.singleton first_line (0., first_parameters,IntMap.empty, UMap.empty) in
    let last_failure=ref LineMap.empty in
    let rec really_break allow_impossible todo demerits=
      let demerits'=break allow_impossible todo demerits in
        if LineMap.cardinal demerits' = 0 then (
          try
            let _=LineMap.find first_line !last_failure in
              print_graph "graph" paragraphs demerits [];
              if Array.length paragraphs>0 && Array.length figures > 0 then
                Printf.printf "No solution, incomplete document. Please report\n";
              demerits';
              (* raise No_solution *)
          with
              Not_found->(
                if Array.length paragraphs>0  && Array.length figures > 0 then (
                  last_failure:=LineMap.add first_line first_parameters !last_failure;
                  really_break true todo0 demerits'
                ) else LineMap.empty
              )
        ) else (
          let (b,(bad,param,_,fig,user))= LineMap.max_binding demerits' in
            if b.paragraph < Array.length paragraphs then (
              try
                let _=LineMap.find b !last_failure in
                    print_graph "graph" paragraphs demerits [];
                    Printf.printf "No solution, incomplete document. Please report\n";
                    demerits'
              with
                  Not_found->(
                    last_failure:=LineMap.add b param !last_failure;
                    really_break true (LineMap.singleton b (bad,param,fig,user)) demerits'
                  )
            ) else
              demerits'
        )
    in
    let demerits=really_break false todo0 LineMap.empty in

    let rec find_last demerits0 b0 bad0 b_params0=
      let (b,(bad,b_params,_,_,_))=LineMap.max_binding demerits0 in
        if b.paragraph=b0.paragraph && b.lastFigure=b0.lastFigure then (
          if bad<bad0 then find_last (LineMap.remove b demerits0) b bad b_params
          else find_last (LineMap.remove b demerits0) b0 bad0 b_params0
        ) else (b0,b_params0)
    in

      try
        let (b0,(bad0,b_params0,_,_,_))=LineMap.max_binding demerits in
        let (b,b_params)=find_last demerits b0 bad0 b_params0 in

        let rec makeParagraphs node result=
          try
            let _,params',next,_,_=LineMap.find node demerits in
              makeParagraphs next ((params',node)::result)
          with
              Not_found->result
        in

        let pages=Array.create (b.page+1) [] in

        let rec makePages=function
            []->()
          | (params,node)::s ->(
              pages.(node.page) <- (params, node)::pages.(node.page);
              makePages s
            )
        in
        let ln=(makeParagraphs b []) in
          print_graph "graph" paragraphs demerits ln;
          Printf.printf "Le graphe a %d nœuds\n" (LineMap.cardinal demerits);
          makePages ln;
          (!log, pages)
      with
          Not_found -> if Array.length paragraphs=0 && Array.length figures=0 then ([],[||]) else (
            Printf.printf "Incomplete document, please report\n";
            [],[||]
          )
end
