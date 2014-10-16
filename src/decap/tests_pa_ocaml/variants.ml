let three = `Int 3;;
let four = `Float 4.;;
let nan = `Not_a_number;;
let l =[three; four; nan];;
let is_positive = function
     | `Int   x -> x > 0
     | `Float x -> x > 0.
  ;;
let exact = List.filter is_positive [three;four];;

type basic_color =
  [ `Black   | `Blue | `Cyan  | `Green
  | `Magenta | `Red  | `White | `Yellow ]

type color =
  [ `Basic of basic_color * [ `Bold | `Regular ]
  | `Gray of int
  | `RGB  of int * int * int ]

type extended_color =
  [ color
  | `RGBA of int * int * int * int ]

let basic_color_to_int : [< `Black | `Blue | `Cyan | `Green | `Magenta | `Red | `White | `Yellow ] -> int
  = function
    | `Black -> 0 | `Red     -> 1 | `Green -> 2 | `Yellow -> 3
    | `Blue  -> 4 | `Magenta -> 5 | `Cyan  -> 6 | `White  -> 7

let color_to_int : [< `Basic of [< `Black | `Blue | `Cyan | `Green | `Magenta | `Red | `White | `Yellow ] * [< `Bold | `Regular ] | `Gray of int | `RGB of int * int * int ] -> int
  = function
    | `Basic (basic_color,weight) ->
      let base = match weight with `Bold -> 8 | `Regular -> 0 in
      base + basic_color_to_int basic_color
    | `RGB (r,g,b) -> 16 + b + g * 6 + r * 36
    | `Gray i -> 232 + i

let extended_color_to_int : extended_color -> int = function
  | `RGBA (r,g,b,a) -> 256 + a + b * 6 + g * 36 + r * 216
  | `Gray x -> 2000 + x
  | (`Basic _ | `RGB _ ) as color -> color_to_int color