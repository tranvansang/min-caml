let x =
let rec gcd m n =
    if m = 0 then n else
        if m <= n then
            gcd m (n - m)
    else
        gcd n (m - n)
in
gcd 4 5
in
()
