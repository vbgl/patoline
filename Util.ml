open Drivers
open Binary
open FontsTypes
open Constants
open Bezier
open CamomileLibrary


type parameters={ format:float*float;
                  lead:float;
                  measure:float;
                  lines_by_page:int;
                  left_margin:float }

type line= { paragraph:int; lastFigure:int; lineEnd:int; lineStart:int; hyphenStart:int; hyphenEnd:int;
             isFigure:bool; height:int; paragraph_height:int; page:int}

module Line=struct
  type t=line
  let compare line0 line1=
    compare line0 line1
end
module LineMap=Map.Make(Line)



type 'a kerningBox='a FontsTypes.kerningBox

type glyph = { contents:UTF8.t; glyph:Fonts.glyph; width:float;
               x0:float; x1:float; y0:float; y1:float }

type drawing=
    Curve of (float*float*curve)
  | Drawing_Box of (float*float*box)

and drawingBox = { drawing_x0:float; drawing_x1:float; drawing_y0:float; drawing_y1:float;
                   drawing_contents:drawing list }

and glueBox = { glue_min_width:float; glue_max_width:float; glue_badness:float->float }

and hyphenBox= { hyphen_normal:box array; hyphenated:(box array* box array) array }

and box=
    GlyphBox of (float*glyph)
  | Kerning of box kerningBox
  | Glue of glueBox
  | Drawing of drawingBox
  | Hyphen of hyphenBox
  | Mark of int
  | Empty


type error_log=
    Overfull_line of line
  | Widow of line
  | Orphan of line


let print_line l=
  Printf.printf "{ paragraph=%d; lineStart=%d; lineEnd=%d; hyphenStart=%d; hyphenEnd=%d; lastFigure=%d; height=%d }\n"
    l.paragraph l.lineStart l.lineEnd l.hyphenStart l.hyphenEnd l.lastFigure l.height
let rec print_box=function
    Glue _->Printf.printf " "
  | GlyphBox (_,x)->Printf.printf "%s" (x.contents)
  | Kerning x->print_box x.kern_contents
  | Hyphen x->Array.iter print_box x.hyphen_normal
  | _->Printf.printf "[]"


let print_text_line lines node=
  print_line node;
  for i=node.lineStart to node.lineEnd-1 do
    print_box (lines.(node.paragraph).(i))
  done;
  print_newline()






let is_glyph=function
    GlyphBox _->true
  | _->false
let is_glue=function
    Glue _->true
  | _->false
let rec box_width comp=function
    GlyphBox (size,x)->x.width*.size/.1000.
  | Glue x->(x.glue_min_width+.(x.glue_max_width-.x.glue_min_width)*.comp)
  | Drawing x->(x.drawing_x1-.x.drawing_x0)
  | Kerning x->(box_width comp x.kern_contents) +. x.advance_width
  | Hyphen x->Array.fold_left (fun s x->s+.box_width comp x) 0. x.hyphen_normal
  | Empty->0.
  | _->0.

let rec box_interval=function
    GlyphBox (size,x)->let y=x.width*.size/.1000. in (y,y)
  | Glue x->(x.glue_min_width, x.glue_max_width)
  | Drawing x->let w=x.drawing_x1-.x.drawing_x0 in w,w
  | Kerning x->let (a,b)=box_interval x.kern_contents in (a +. x.advance_width, b +. x.advance_width)
  | Hyphen x->boxes_interval x.hyphen_normal
  | _->(0.,0.)

and boxes_interval boxes=
  let a=ref 0. in let b=ref 0. in
    for i=0 to Array.length boxes-1 do
      let (u,v)=box_interval (boxes.(i)) in
        a:= !a+.u;b:= !b+.v
    done;
    (!a,!b)

let rec lower_y x w=match x with
    GlyphBox (size,y)->y.y0*.size/.1000.
  | Drawing y->y.drawing_y0
  | Glue _->0.
  | Kerning y->(lower_y y.kern_contents w) +. y.kern_y0
  | _->0.

let rec upper_y x w=match x with
    GlyphBox (size,y)->y.y1*.size/.1000.
  | Drawing y->y.drawing_y1
  | Glue _->0.
  | Kerning y->(upper_y y.kern_contents w) +. y.kern_y0
  | _-> 0.

let line_height paragraphs node=
  let rec line_height boxes k maxk min_height max_height=
    if k>=maxk then (min_height,max_height) else (
      match boxes.(k) with
          Hyphen x->(
            let a,b=line_height x.hyphen_normal 0 (Array.length x.hyphen_normal) min_height max_height in
              line_height boxes (k+1) maxk a b
          )
        | _->(line_height boxes (k+1) maxk
                (min min_height (lower_y boxes.(k) 0.))
                (max max_height (upper_y boxes.(k) 0.)))
    )
  in
  let a0,b0=
    if node.hyphenStart>=0 then (
      match paragraphs.(node.paragraph).(node.lineStart) with
          Hyphen x->
            (let hyp=snd x.hyphenated.(node.hyphenStart) in
             let u,v=line_height hyp 0 (Array.length hyp) 0. 0. in
               line_height paragraphs.(node.paragraph) (node.lineStart+1) node.lineEnd u v)
        | _->line_height paragraphs.(node.paragraph) (node.lineStart+1) node.lineEnd 0. 0.
    ) else (line_height paragraphs.(node.paragraph) (node.lineStart+1) node.lineEnd 0. 0.)
  in
    if node.hyphenEnd>=0 then (
      match paragraphs.(node.paragraph).(node.lineEnd) with
          Hyphen x->let hyp=fst x.hyphenated.(node.hyphenEnd) in
            line_height hyp 0 (Array.length hyp) a0 b0
        | _->a0,b0
    ) else a0,b0

let glyphCache_=ref StrMap.empty

let glyphCache cur_font gl cont=
  let font=try StrMap.find (Fonts.fontName cur_font) !glyphCache_ with
        Not_found->(let fontCache=ref IntMap.empty in
                      glyphCache_:=StrMap.add (Fonts.fontName cur_font) fontCache !glyphCache_;
                      fontCache)
  in
    try IntMap.find gl !font with
        Not_found->
          (let glyph=Fonts.loadGlyph cur_font gl in
           let (y0,y1)=List.fold_left (fun (a,b) (_,y)->
                                         let (c,d)=Bezier.bernstein_extr y in
                                           (min a c, max b d)
                                      ) (1./.0., -1./.0.) (Fonts.outlines glyph)
           in
           let (x0,x1)=List.fold_left (fun (a,b) (y,_)->
                                         let (c,d)=Bezier.bernstein_extr y in
                                           (min a c, max b d)
                                      ) (1./.0., -1./.0.) (Fonts.outlines glyph)
           in
           let loaded={ contents=cont;
                        glyph=glyph; width=Fonts.glyphWidth glyph;
                        x0=x0; x1=x1;
                        y0=y0; y1=y1 } in
             font:=IntMap.add gl loaded !font;
             loaded)


let glyph_of_string substitution_ positioning_ font fsize str =
  let rec make_codes idx codes=
    try
      let c=Fonts.glyph_of_char font (UTF8.look str idx) in
        make_codes (UTF8.next str idx) (GlyphID (UTF8.init 1 (fun _->UTF8.look str idx),c)::codes)
    with
        _->List.rev codes
  in
  let codes=substitution_ (make_codes (UTF8.first str) []) in
  let kerns=positioning_ codes in

  let rec kern=function
      GlyphID (c,h)::s ->let y=glyphCache font h c in GlyphBox (fsize, y)::kern s
    | KernID h::s->
        (match h.kern_contents with
             KernID h'->kern (KernID { advance_height=h.advance_height;
                                       advance_width=h.advance_width;
                                       kern_x0=h.kern_x0 +. h'.kern_x0;
                                       kern_y0=h.kern_y0 +. h'.kern_y0;
                                       kern_contents=h'.kern_contents }::s)
           | GlyphID (c,h')->(let y=glyphCache font h' c in
                            Kerning { advance_height=h.advance_height*.(fsize)/.1000.;
                                      advance_width=h.advance_width*.(fsize)/.1000.;
                                      kern_x0=h.kern_x0*.(fsize)/.1000.;
                                      kern_y0=h.kern_y0*.(fsize)/.1000.;
                                      kern_contents=GlyphBox (fsize, y) }::(kern s))
        )
    | []->[]
  in
    kern kerns


let hyphenate tree subs kern font fsize str=
  let hyphenated=Hyphenate.hyphenate str tree in
  let pos=Array.make (List.length hyphenated-1) ([||],[||]) in
  let rec hyph l i cur=match l with
      []->[Hyphen { hyphen_normal=Array.of_list (glyph_of_string subs kern font fsize str); hyphenated=pos }]
    | h::s->(
        pos.(i)<-(Array.of_list (glyph_of_string subs kern font fsize (cur^"-")),
                  Array.of_list (glyph_of_string subs kern font fsize (List.fold_left (^) "" l)));
        hyph s (i+1) (cur^h)
      )
  in
    match hyphenated with
        []->glyph_of_string subs kern font fsize str
      | h::s->hyph s 0 h

let knuth_h_badness w1 w = 100.*.(abs_float (w-.w1)) ** 3.
