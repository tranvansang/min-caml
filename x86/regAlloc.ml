open Asm

(* for register coalescing *)
(* [XXX] Callがあったら、そこから先は無意味というか逆効果なので追わない。
         そのために「Callがあったかどうか」を返り値の第1要素に含める。 *)
let rec target' src (dest, t) = function
  | Mov(x, info) when x = src && is_reg dest ->
          (
          match t with
            | Type.Unit _ -> assert false
            | Type.Float _ -> assert false
              | _ -> ()
          );

      false, [dest]
  | FMovD(x, info) when x = src && is_reg dest ->
          (match t with
          | Type.Float _ -> ()
          | _ -> assert false
          );
      false, [dest]
  | IfEq(_, _, e1, e2, info) | IfLE(_, _, e1, e2, info) | IfGE(_, _, e1, e2, info)
  | IfFEq(_, _, e1, e2, info) | IfFLE(_, _, e1, e2, info) ->
      let c1, rs1 = target src (dest, t) e1 in
      let c2, rs2 = target src (dest, t) e2 in
      c1 && c2, rs1 @ rs2
  | CallCls(x, ys, zs, info) ->
      true, (target_args src regs 0 ys @
	     target_args src fregs 0 zs @
             if x = src then [reg_cl] else [])
  | CallDir(_, ys, zs, info) ->
      true, (target_args src regs 0 ys @
	     target_args src fregs 0 zs)
  | _ -> false, []
and target src dest = function (* register targeting (caml2html: regalloc_target) *)
  | Ans(exp, info) -> target' src dest exp
  | Let(xt, exp, e, info) ->
      let c1, rs1 = target' src xt exp in
      if c1 then true, rs1 else
      let c2, rs2 = target src dest e in
      c2, rs1 @ rs2
and target_args src all n = function (* auxiliary function for Call *)
  | [] -> []
  | y :: ys when src = y (* && n <= List.length all - 2 *) ->
      all.(n) :: target_args src all (n + 1) ys
  | _ :: ys -> target_args src all (n + 1) ys
(* "register sourcing" (?) as opposed to register targeting *)
(* （x86の2オペランド命令のためのregister coalescing） *)
let rec source t = function
  | Ans(exp, info) -> source' t exp
  | Let(_, _, e, info) -> source t e
and source' t = function
  | Mov(x, info) | Neg(x, info) | Add(x, C _, info) | Sub(x, _, info) | FMovD(x, info) | FNegD(x, info) | FSubD(x, _, info) | FDivD(x, _, info) -> [x]
  | Add(x, V y, info) | FAddD(x, y, info) | FMulD(x, y, info) -> [x; y]
  | IfEq(_, _, e1, e2, info) | IfLE(_, _, e1, e2, info) | IfGE(_, _, e1, e2, info) | IfFEq(_, _, e1, e2, info) | IfFLE(_, _, e1, e2, info) ->
      source t e1 @ source t e2
  | CallCls _ | CallDir _ -> (match t with Type.Unit _ -> [] | Type.Float _-> [fregs.(0)] | _ -> [regs.(0)])
  | _ -> []

type alloc_result = (* allocにおいてspillingがあったかどうかを表すデータ型 *)
  | Alloc of Id.t (* allocated register *)
  | Spill of Id.t (* spilled variable *)
let rec alloc cont regenv x t prefer =
  (* allocate a register or spill a variable *)
  assert (not (M.mem x regenv));
  let all =
    match t with
    | Type.Unit _-> [] (* dummy *)
    | Type.Float _ -> allfregs
    | _ -> allregs in
  if all = [] then Alloc("%unit", Info.dump ()) else (* [XX] ad hoc *)
  if is_reg x then Alloc(x) else
  let free = fv cont in
  try
    let live = (* 生きているレジスタ *)
      List.fold_left
        (fun live y ->
	  if is_reg y then S.add y live else
          try S.add (M.find y regenv) live
          with Not_found -> live)
        S.empty
        free in
    let r = (* そうでないレジスタを探す *)
      List.find
        (fun r -> not (S.mem r live))
        (prefer @ all) in
    (* Format.eprintf "allocated %s to %s@." x r; *)
    Alloc(r)
  with Not_found ->
    Format.eprintf "register allocation failed for %s@." (M.to_string x);
    let y = (* 型の合うレジスタ変数を探す *)
      List.find
        (fun y ->
	  not (is_reg y) &&
          try List.mem (M.find y regenv) all
          with Not_found -> false)
        (List.rev free) in
    Format.eprintf "spilling %s from %s@."(Id.to_string y) (M.to_string (M.find y regenv));
    Spill(y)

(* auxiliary function for g and g'_and_restore *)
let add x r regenv =
  if is_reg x then (assert (x = r); regenv) else
  M.add x r regenv

(* auxiliary functions for g' *)
exception NoReg of Id.t * Type.t * Info.t
let find x t regenv info =
  if is_reg x then x else
  try M.find x regenv
  with Not_found -> raise (NoReg(x, t, info))
let find' x' regenv info=
  match x' with
  | V(x) -> V(find x (Type.Int info) regenv info)
  | c -> c

let rec g dest cont regenv = function (* 命令列のレジスタ割り当て (caml2html: regalloc_g) *)
  | Ans(exp, info) -> g'_and_restore dest cont regenv exp
  | Let((x, t) as xt, exp, e, info) ->
      assert (not (M.mem x regenv));
      let cont' = concat e dest cont in
      let (e1', regenv1) = g'_and_restore xt cont' regenv exp in
      let (_call, targets) = target x dest cont' in
      let sources = source t e1' in
      (* レジスタ間のmovよりメモリを介するswapのほうが問題なので、sourcesよりtargetsを優先 *)
      (match alloc cont' regenv1 x t (targets @ sources) with
      | Spill(y) ->
	  let r = M.find y regenv1 in
	  let (e2', regenv2) = g dest cont (add x r (M.remove y regenv1)) e in
	  let save =
	    try Save(M.find y regenv, y, info)
	    with Not_found -> Nop info in	    
	  (seq(save, concat e1' (r, t) e2', info), regenv2)
      | Alloc(r) ->
	  let (e2', regenv2) = g dest cont (add x r regenv1) e in
	  (concat e1' (r, t) e2', regenv2))
and g'_and_restore dest cont regenv exp = (* 使用される変数をスタックからレジスタへRestore (caml2html: regalloc_unspill) *)
  try g' dest cont regenv exp
  with NoReg(x, t, info) ->
    ((* Format.eprintf "restoring %s@." x; *)
     g dest cont regenv (Let((x, t), Restore(x, info), Ans(exp, info), info)))
and g' dest cont regenv = function (* 各命令のレジスタ割り当て (caml2html: regalloc_gprime) *)
  | Nop info | Set (_, info) | SetL (_, info) | Comment (_, info) | Restore (_, info) as exp -> (Ans(exp, info), regenv)
  | Mov(x, info) -> (Ans(Mov(find x (Type.Int info) regenv info, info), info), regenv)
  | Neg(x, info) -> (Ans(Neg(find x (Type.Int info) regenv info, info), info), regenv)
  | Add(x, y', info) -> (Ans(Add(find x (Type.Int info) regenv info, find' y' regenv info, info), info), regenv)
  | Sub(x, y', info) -> (Ans(Sub(find x (Type.Int info) regenv info, find' y' regenv info, info), info), regenv)
  | Ld(x, y', i, info) -> (Ans(Ld(find x (Type.Int info) regenv info, find' y' regenv info, i, info), info), regenv)
  | St(x, y, z', i, info) -> (Ans(St(find x (Type.Int info) regenv info, find y (Type.Int info) regenv info, find' z' regenv info, i, info), info), regenv)
  | FMovD(x, info) -> (Ans(FMovD(find x (Type.Float info) regenv info, info), info), regenv)
  | FNegD(x, info) -> (Ans(FNegD(find x (Type.Float info) regenv info, info), info), regenv)
  | FAddD(x, y, info) -> (Ans(FAddD(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, info), info), regenv)
  | FSubD(x, y, info) -> (Ans(FSubD(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, info), info), regenv)
  | FMulD(x, y, info) -> (Ans(FMulD(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, info), info), regenv)
  | FDivD(x, y, info) -> (Ans(FDivD(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, info), info), regenv)
  | LdDF(x, y', i, info) -> (Ans(LdDF(find x (Type.Int info) regenv info, find' y' regenv info, i, info), info), regenv)
  | StDF(x, y, z', i, info) -> (Ans(StDF(find x (Type.Float info) regenv info, find y (Type.Int info) regenv info, find' z' regenv info, i, info), info), regenv)
  | IfEq(x, y', e1, e2, info) as exp -> g'_if dest cont regenv exp (fun e1' e2' -> IfEq(find x (Type.Int info) regenv info, find' y' regenv info, e1', e2', info)) e1 e2 info
  | IfLE(x, y', e1, e2, info) as exp -> g'_if dest cont regenv exp (fun e1' e2' -> IfLE(find x (Type.Int info) regenv info, find' y' regenv info, e1', e2', info)) e1 e2 info
  | IfGE(x, y', e1, e2, info) as exp -> g'_if dest cont regenv exp (fun e1' e2' -> IfGE(find x (Type.Int info) regenv info, find' y' regenv info, e1', e2', info)) e1 e2 info
  | IfFEq(x, y, e1, e2, info) as exp -> g'_if dest cont regenv exp (fun e1' e2' -> IfFEq(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, e1', e2', info)) e1 e2 info
  | IfFLE(x, y, e1, e2, info) as exp -> g'_if dest cont regenv exp (fun e1' e2' -> IfFLE(find x (Type.Float info) regenv info, find y (Type.Float info) regenv info, e1', e2', info)) e1 e2 info
  | CallCls(x, ys, zs, info) as exp -> g'_call dest cont regenv exp (fun ys zs -> CallCls(find x (Type.Int info) regenv info, ys, zs, info)) ys zs info
  | CallDir(l, ys, zs, info) as exp -> g'_call dest cont regenv exp (fun ys zs -> CallDir(l, ys, zs, info)) ys zs info
  | Save(x, y, info) -> assert false
and g'_if dest cont regenv exp constr e1 e2 info = (* ifのレジスタ割り当て (caml2html: regalloc_if) *)
  let (e1', regenv1) = g dest cont regenv e1 in
  let (e2', regenv2) = g dest cont regenv e2 in
  let regenv' = (* 両方に共通のレジスタ変数だけ利用 *)
    List.fold_left
      (fun regenv' x ->
        try
	  if is_reg x then regenv' else
          let r1 = M.find x regenv1 in
          let r2 = M.find x regenv2 in
          if r1 <> r2 then regenv' else
	  M.add x r1 regenv'
        with Not_found -> regenv')
      M.empty
      (fv cont) in
  (List.fold_left
     (fun e x ->
       if x = fst dest || not (M.mem x regenv) || M.mem x regenv' then e else
       seq(Save(M.find x regenv, x, info), e, info)) (* そうでない変数は分岐直前にセーブ *)
     (Ans(constr e1' e2', info))
     (fv cont),
   regenv')
and g'_call dest cont regenv exp constr ys zs info = (* 関数呼び出しのレジスタ割り当て (caml2html: regalloc_call) *)
  (List.fold_left
     (fun e x ->
       if x = fst dest || not (M.mem x regenv) then e else
       seq(Save(M.find x regenv, x, info), e, info))
     (Ans(constr
	    (List.map (fun y -> find y (Type.Int info) regenv info) ys)
	    (List.map (fun z -> find z (Type.Float info) regenv info) zs), info))
     (fv cont),
   M.empty)

let h { name = Id.L(_) as x; args = ys; fargs = zs; body = e; ret = t } = (* 関数のレジスタ割り当て (caml2html: regalloc_h) *)
  let regenv = M.add (Id.to_t x) reg_cl M.empty in
  let (i, arg_regs, regenv) =
    List.fold_left
      (fun (i, arg_regs, regenv) y ->
        let r = regs.(i) in
        (i + 1,
	 arg_regs @ [r],
	 (assert (not (is_reg y));
	  M.add y r regenv)))
      (0, [], regenv)
      ys in
  let (d, farg_regs, regenv) =
    List.fold_left
      (fun (d, farg_regs, regenv) z ->
        let fr = fregs.(d) in
        (d + 1,
	 farg_regs @ [fr],
	 (assert (not (is_reg z));
	  M.add z fr regenv)))
      (0, [], regenv)
      zs in
  let a =
    match t with
    | Type.Unit info -> Id.gentmp (Type.Unit info) info
    | Type.Float info -> fregs.(0)
    | _ -> regs.(0) in
  let info = Asm.get_info_t e in
  let (e', regenv') = g (a, t) (Ans(Mov(a, info), info)) regenv e in
  { name = x; args = arg_regs; fargs = farg_regs; body = e'; ret = t }

let f (Prog(data, fundefs, e)) = (* プログラム全体のレジスタ割り当て (caml2html: regalloc_f) *)
  Format.eprintf "register allocation: may take some time (up to a few minutes, depending on the size of functions)@.";
  let fundefs' = List.map h fundefs in
  let info = Asm.get_info_t e in
  let e', regenv' = g (Id.gentmp (Type.Unit info) info, Type.Unit info) (Ans(Nop info, info)) M.empty e in
  Prog(data, fundefs', e')
