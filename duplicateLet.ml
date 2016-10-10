let rec has_side_effect = function
  | KNormal.Unit _
  | KNormal.Int _
  | KNormal.Float _
  | KNormal.Neg _
  | KNormal.Add _
  | KNormal.Sub _
  | KNormal.FNeg _
  | KNormal.FAdd _
  | KNormal.FSub _
  | KNormal.FMul _
  | KNormal.FDiv _
  | KNormal.Var _
  | KNormal.Tuple _
  | KNormal.Get _
  | KNormal.ExtArray _
  -> false
  | KNormal.LetTuple (_, _, e, _)
  -> has_side_effect e

  | KNormal.IfEq (_, _, t1, t2, _)
  | KNormal.IfLE(_, _, t1, t2, _)
  | KNormal.Let (_, t1, t2, _ )
  -> (has_side_effect t1) || (has_side_effect t2)

  | KNormal.LetRec (f, t1, _)
  -> (has_side_effect (f.body)) || (has_side_effect t1)

  | KNormal.App _
  | KNormal.Put _
  | KNormal.ExtFunApp _
  -> true

let rec g env exp = match exp with
    | KNormal.Let ((x, t), e1, e2, info) ->
            (
                match e1 with
                  | KNormal.Unit _ | KNormal.Int _ | KNormal.Float _ ->
                            let e2', _ = g env e2
                            in
                                KNormal.Let ((x, t), e1, e2', info), env

                    | _ ->
                        try
                            (*try finding occurence of exxpression e1 in current enviroment*)
                            let y = M1.find e1 env
                            in
                            (*if found, re-create let by replacing e1 with its mapping in current enviroment(y)*)
                            let e2', _ = g env e2
                            in
                            KNormal.Let ((x, t), y, e2', info), env
                        with Not_found ->

                            (*if not found*)
                            (*evaluate e1*)
                            let e1', _ = g env e1
                            in
                            let env' =
                                if has_side_effect e1 then
                                    env
                                else
                                    (*map e1 to variable x*)
                                    M1.add e1 (KNormal.Var(x, Id.get_info x)) env
                            in
                            let e2', _ = g env' e2
                            in
                                KNormal.Let ((x, t), e1', e2', info), env
            )
  | KNormal.Unit _
  | KNormal.Int _
  | KNormal.Float _
  | KNormal.Neg _
  | KNormal.Add _
  | KNormal.Sub _
  | KNormal.FNeg _
  | KNormal.FAdd _
  | KNormal.FSub _
  | KNormal.FMul _
  | KNormal.FDiv _
  | KNormal.App _
  | KNormal.Tuple _
  | KNormal.Var _
  | KNormal.Get _
  | KNormal.Put _
  | KNormal.ExtArray _
  | KNormal.ExtFunApp _
  -> exp, env
  | KNormal.LetTuple (a, b,e, info)
  -> KNormal.LetTuple(a, b, fst (g env e), info), env

  | KNormal.IfEq (id1, id2, t1, t2, info)
  -> KNormal.IfEq(id1, id2, fst (g env t1), fst (g env t2), info), env

  | KNormal.IfLE (id1, id2, t1, t2, info)
  -> KNormal.IfLE(id1, id2, fst (g env t1), fst (g env t2), info), env

  | KNormal.Let (idtype, t1, t2, info)
  -> KNormal.Let(idtype, fst (g env t1), fst (g env t2), info), env

  | KNormal.LetRec (f, e, info)
  -> 
      KNormal.LetRec({name = f.name; args = f.args; body = fst (g env (f.body))}, fst (g env e), info), env

    (*env maps expression to variable (Syntax.Var type)*)
let f e =
    let refined = fst (g M1.empty e)
    in
    Printf.printf "\n\n code before removing duplicate elements:\n%s" (KNormal.to_string e);
    Printf.printf "\n\ncode after removing duplicate elements:\n%s" (KNormal.to_string refined);
    refined
