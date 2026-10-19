# shellcheck shell=bash
# Model table handling (data/models.tsv) and name normalisation.

MODELS_FILE=${MODELS_FILE:-$ROOT_DIR/data/models.tsv}

norm() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9'; }

list_models() { grep -v '^#' "$MODELS_FILE" | cut -f1; }

# model_field MODEL N   (1=model 2=ppd 3=colour 4=open 5=note)
model_field() {
    local want; want=$(norm "$1")
    awk -F'\t' -v w="$want" -v n="$2" '
        /^#/ || NF<2 {next}
        { k=toupper($1); gsub(/[^A-Z0-9]/,"",k); if (k==w) { print $n; exit } }' "$MODELS_FILE"
}

# resolve_model "free text"  -> canonical model name from the table, or empty.
# Handles "Canon LBP6300dn", "LBP-810", "LBP7210Cdn", "LBP3018B" ... by dropping trailing
# letters until a table entry matches.
resolve_model() {
    local s; s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    local tok
    tok=$(printf '%s' "$s" | grep -oE 'LBP[- ]?[0-9]+[A-Z]*' | head -1)
    [ -n "$tok" ] || return 1
    local n; n=$(norm "$tok")
    while [ ${#n} -ge 6 ]; do
        local f; f=$(model_field "$n" 1)
        if [ -n "$f" ]; then printf '%s\n' "$f"; return 0; fi
        n=${n%?}
    done
    return 1
}

# pick_model_menu -> prints chosen model on stdout (menu on stderr)
pick_model_menu() {
    local models; mapfile -t models < <(list_models)
    [ -t 0 ] || die "No printer detected and no terminal for a menu; use --model <name>"
    {
        echo "Select your printer model:"
    } >&2
    local PS3="Number: " m
    select m in "${models[@]}"; do
        [ -n "${m:-}" ] && { printf '%s\n' "$m"; return 0; }
    done </dev/tty >&2
    return 1
}
