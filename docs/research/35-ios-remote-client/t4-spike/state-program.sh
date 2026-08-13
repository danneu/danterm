#!/bin/bash
# The pane-side half of the `state` scenario. It establishes terminal state that no later byte
# restates -- alternate screen, hidden cursor, mouse tracking, bracketed paste, application cursor
# keys -- and then keeps emitting so a client that attaches afterwards stays fed.
printf '\033[?1049h\033[H\033[2JALT-BEFORE-JOIN\r\n'
printf '\033[?25l\033[?1000h\033[?2004h\033[?1h'
for i in 1 2 3 4 5 6 7 8 9 10; do
    printf 'tick %s\r\n' "$i"
    sleep 1
done
printf '\033[?1049l'
