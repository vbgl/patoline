(*
  Copyright Tom Hirschowitz, Florian Hatat, Pierre-Etienne Meunier,
  Christophe Raffalli and others, 2012.

  This file is part of Patoline.

  Patoline is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Patoline is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with Patoline.  If not, see <http://www.gnu.org/licenses/>.
*)
open Str

module C=Map.Make (struct type t=char let compare=compare end)

type ptree=
  Node of (char array)*(ptree C.t)
  | Exception of (string list)*(ptree C.t)

let is_num c = c>='0' && c<='9'

let insert tree a=
  let breaks0=Array.make (String.length a) '0' in
  let j=ref 0 in
    for i=0 to String.length a-1 do
      if is_num a.[i] then breaks0.(!j)<-a.[i] else
        incr j
    done;
    let breaks=Array.sub breaks0 0 (!j+1) in
    let rec insert i tree=
      if i>=String.length a then Node (breaks, C.empty) else
        if is_num a.[i] then insert (i+1) tree else
          (match tree with
             Node (x,t)->
               (let tree'=try C.find a.[i] t with Not_found->Node ([||], C.empty) in
                  Node (x, C.add a.[i] (insert (i+1) tree') t))
             | Exception (x,t)->
                 (let tree'=try C.find a.[i] t with Not_found->Node ([||], C.empty) in
                    Exception (x, C.add a.[i] (insert (i+1) tree') t))
          )
    in
      insert 0 tree

let insert_exception tree a0=
  let a="."^(List.fold_left (^) "" a0)^"." in

  let rec insert i = function

      Exception (_,_) as t when i>=String.length a-1 -> t
    | Exception (x,t)->
        (
          let t'=try C.find a.[i] t with Not_found->Node ([||], C.empty) in
            Exception (x, C.add a.[i] (insert (i+1) t') t)
        )
    | Node (x,t) when i>=String.length a-1 -> Exception (a0,t)
    | Node (x,t)->
        (
          let t'=try C.find a.[i] t with Not_found->Node ([||], C.empty) in
            Node (x, C.add a.[i] (insert (i+1) t') t)
        )
  in
    insert 0 tree


exception Exp of (string list)

let rec dash_hyphen s=if String.length s=0 then [] else
  try
    let i=String.index s '-' in
    let s0=String.sub s 0 i in
    let next=(dash_hyphen (String.sub s (i+1) (String.length s-i-1))) in
      if String.length s0=0 then next else s0::next
  with
      Not_found->if String.length s=0 then [] else [s]

let hyphenate tree a0=
  if String.length a0<=4 then [a0] else
    match dash_hyphen a0 with
        _::_::_ as l->l
      | _->(
          let a=String.create (String.length a0+2) in
            String.blit a0 0 a 1 (String.length a0);
            a.[0]<-'.';
            a.[String.length a-1]<-'.';
            let breaks=Array.create (String.length a+1) '0' in
            let rec hyphenate i j t=if j>=String.length a then () else match t with
              | Exception (x,_) when i=0 && j=String.length a-1->(
                  (* raise (Exp x) *)
                  ()
                )
              | Exception (_,t)->
                  (
                    try
                      let t'=C.find a.[j] t in
                        hyphenate i (j+1) t'
                    with
                        Not_found->())
              | Node (x,t) -> (
                  if Array.length x>0 then (
                    for k=0 to Array.length x-1 do
                      breaks.(i+k)<-max breaks.(i+k) x.(k)
                    done);
                  try
                    let t'=C.find a.[j] t in
                      hyphenate i (j+1) t'
                  with
                      Not_found->()
                )
            in
              for i=0 to String.length a-1 do
                hyphenate i i tree;
              done;

              let rec make_hyphens i j=
                if j>=String.length a-2 then [String.sub a i (j-i+1)] else
                  if (int_of_char breaks.(j+1)-int_of_char '0') mod 2 = 1 && j>=3 && j<String.length a0-3 then
                    (String.sub a i (j-i+1)) :: make_hyphens (j+1) (j+1)
                  else
                    make_hyphens i (j+1)

              in
                make_hyphens 1 3
        )
let empty=Node ([||], C.empty)

(* let patterns= *)
(*   let i=open_in_bin "patterns" in *)
(*   let str=String.create (in_channel_length i) in *)
(*     really_input i str 0 (in_channel_length i); *)
(*     let s=split (regexp "[\n\t ]") str in *)
(*       close_in i; *)
(*       s *)

(* let tree0 = List.fold_left insert (Node ([||],C.empty)) patterns *)

(* let tree = List.fold_left insert_exception tree0 *)
(*   [["as";"so";"ciate"]; ["as";"so";"ciates"]; ["dec";"li";"na";"tion"]; *)
(*    ["oblig";"a";"tory"]; ["phil";"an";"thropic"]; ["present"]; ["presents"]; *)
(*    ["project"]; ["projects"]; ["reci";"procity"]; ["re";"cog";"ni";"zance"]; *)
(*    ["ref";"or";"ma";"tion"]; ["ret";"ri";"bu";"tion";"ta";"ble"]] *)

(* let _= *)
(*   let o=open_out "dict_en" in *)
(*     output_value o tree; *)
(*     close_out o *)

(* let tree= *)
(*   let i=open_in_bin "dict_en" in *)
(*   let inp=input_value i in *)
(*     close_in i; *)
(*     inp *)
(* let _=let str="associated" in hyphenate tree str *)
