#!/usr/bin/env bash
# Paints a true-color background for interactively testing cursor contrast.

old_stty=$(stty -g)
x=1
y=1

restore() {
    printf '\033[0m\033[0 q\033[?1049l'
    stty "$old_stty"
}

trap restore EXIT INT TERM

draw() {
    cols=$(tput cols)
    rows=$(tput lines)

    ((x > cols)) && x=$cols
    ((y > rows)) && y=$rows

    printf '\033[2J\033[H'

    row=1
    while ((row <= rows)); do
        col=1
        while ((col <= cols)); do
            hue=$(((col - 1) * 1536 / cols))
            sector=$((hue / 256))
            part=$((hue % 256))

            case $sector in
                0) r=255; g=$part; b=0 ;;
                1) r=$((255 - part)); g=255; b=0 ;;
                2) r=0; g=255; b=$part ;;
                3) r=0; g=$((255 - part)); b=255 ;;
                4) r=$part; g=0; b=255 ;;
                *) r=255; g=0; b=$((255 - part)) ;;
            esac

            brightness=$((35 + (row - 1) * 65 / (rows > 1 ? rows - 1 : 1)))
            r=$((r * brightness / 100))
            g=$((g * brightness / 100))
            b=$((b * brightness / 100))

            printf '\033[48;2;%d;%d;%dm ' "$r" "$g" "$b"
            ((col++))
        done
        printf '\033[0m'
        ((row < rows)) && printf '\n'
        ((row++))
    done

    printf '\033[0m\033[%d;%dH' "$y" "$x"
}

printf '\033[?1049h\033[2 q'
stty -echo -icanon min 1 time 0
trap draw WINCH

draw

while IFS= read -rsn1 key; do
    case "$key" in
        q | Q) break ;;
        $'\033')
            IFS= read -rsn2 -t 0.1 sequence || continue
            case "$sequence" in
                '[A') ((y > 1)) && ((y--)) ;;
                '[B') ((y < rows)) && ((y++)) ;;
                '[C') ((x < cols)) && ((x++)) ;;
                '[D') ((x > 1)) && ((x--)) ;;
            esac
            ;;
    esac

    printf '\033[%d;%dH' "$y" "$x"
done
