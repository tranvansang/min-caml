open KNormal

let memi x env =
  try (match M.find x env with Int(_) -> true | _ -> false)
  with Not_found -> false
let memf x env =
  try (match M.find x env with Float(_) -> true | _ -> false)
  with Not_found -> false
let memt x env =
  try (match M.find x env with Tuple(_) -> true | _ -> false)
  with Not_found -> false

let findi x env = (match M.find x env with Int(i, info) -> i | _ -> raise Not_found)
let findf x env = (match M.find x env with Float(d, info) -> d | _ -> raise Not_found)
let findt x env = (match M.find x env with Tuple(ys, info) -> ys | _ -> raise Not_found)

let rec g env = function (* 定数畳み込みルーチン本体 (caml2html: constfold_g) *)
  | Var(x, info) when memi x env -> Int(findi x env, info)
  (* | Var(x) when memf x env -> Float(findf x env) *)
  (* | Var(x) when memt x env -> Tuple(findt x env) *)
  | Neg(x, info) when memi x env -> Int(-(findi x env), info)
  | Add(x, y, info) when memi x env && memi y env -> Int(findi x env + findi y env, info) (* 足し算のケース (caml2html: constfold_add) *)
  | Sub(x, y, info) when memi x env && memi y env -> Int(findi x env - findi y env, info)
  | FNeg(x, info) when memf x env -> Float(-.(findf x env), info)
  | FAdd(x, y, info) when memf x env && memf y env -> Float(findf x env +. findf y env, info)
  | FSub(x, y, info) when memf x env && memf y env -> Float(findf x env -. findf y env, info)
  | FMul(x, y, info) when memf x env && memf y env -> Float(findf x env *. findf y env, info)
  | FDiv(x, y, info) when memf x env && memf y env -> Float(findf x env /. findf y env, info)
  | IfEq(x, y, e1, e2, info) when memi x env && memi y env -> if findi x env = findi y env then g env e1 else g env e2
  | IfEq(x, y, e1, e2, info) when memf x env && memf y env -> if findf x env = findf y env then g env e1 else g env e2
  | IfEq(x, y, e1, e2, info) -> IfEq(x, y, g env e1, g env e2, info)
  | IfLE(x, y, e1, e2, info) when memi x env && memi y env -> if findi x env <= findi y env then g env e1 else g env e2
  | IfLE(x, y, e1, e2, info) when memf x env && memf y env -> if findf x env <= findf y env then g env e1 else g env e2
  | IfLE(x, y, e1, e2, info) -> IfLE(x, y, g env e1, g env e2, info)
  | Let((x, t), e1, e2, info) -> (* letのケース (caml2html: constfold_let) *)
      let e1' = g env e1 in
      let e2' = g (M.add x e1' env) e2 in
      Let((x, t), e1', e2', info)
  | LetRec({ name = x; args = ys; body = e1 }, e2, info) ->
      LetRec({ name = x; args = ys; body = g env e1 }, g env e2, info)
  | LetTuple(xts, y, e, info) when memt y env ->
      List.fold_left2
	(fun e' xt z -> Let(xt, Var(z, info), e', info))
	(g env e)
	xts
	(findt y env)
  | LetTuple(xts, y, e, info) -> LetTuple(xts, y, g env e, info)
  | e -> e

let f = g M.empty
