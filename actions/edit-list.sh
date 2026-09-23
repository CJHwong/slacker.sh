# shellcheck shell=bash
# help: write | set cells in one Slack List row, found by a column value
# actions/edit-list.sh — write cells into one row of a Slack List.
# The row is found by --where against what read-list shows, never by position,
# so the caller names the row the way a person would. Columns are named, and
# each value is encoded for its column type here: Slack takes only the schema
# column id, the option value (not its label), a user id, and a YYYY-MM-DD date,
# all verified against slackLists.items.update. Writing needs lists:write;
# reading the list first needs only files:read, the same route read-list takes.
# Sourced by slacker.sh with the action args as "$@".

slacker_edit_list() {
  local input="" where="" expects='[]' sets='[]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --where)  slacker_flag_value "$1" "$#" || return 1; where="$2"; shift 2 ;;
      --expect) slacker_flag_value "$1" "$#" || return 1
                expects=$(jq -cn --argjson a "$expects" --arg v "$2" '$a + [$v]'); shift 2 ;;
      --set)    slacker_flag_value "$1" "$#" || return 1
                sets=$(jq -cn --argjson a "$sets" --arg v "$2" '$a + [$v]'); shift 2 ;;
      -*)       echo "edit-list: unknown flag $1" >&2; return 1 ;;
      *)        input="$1"; shift ;;
    esac
  done
  if [ -z "$input" ] || [ -z "$where" ] || [ "$sets" = '[]' ]; then
    echo "usage: slacker.sh edit-list <Fid|permalink> --where 'Column=value|Column^=prefix' [--expect 'Column=value']... --set 'Column=value'..." >&2
    return 1
  fi

  local listid
  listid=$(slacker_canvas_id_from "$input")
  [ -n "$listid" ] || { slacker_error no_list_id escalate "no list id found in '$input'." \
    "Pass a list file id (Fxxxx) or a Slack list permalink."; return 1; }

  local rawf umap cmap users_file channels_file
  rawf=$(mktemp "${TMPDIR:-/tmp}/slacker_list.XXXXXX")
  slacker_fetch_list "$listid" "$rawf" || { rm -f "$rawf"; return 1; }
  users_file=$(slacker_users_cache) || { rm -f "$rawf"; return 1; }
  channels_file=$(slacker_channels_cache) || { rm -f "$rawf"; return 1; }
  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_lumap.XXXXXX")
  slacker_augment_users "$users_file" < "$rawf" > "$umap"
  cmap=$(mktemp "${TMPDIR:-/tmp}/slacker_lcmap.XXXXXX")
  slacker_augment_channels "$channels_file" < "$rawf" > "$cmap"

  local plan
  # An empty plan would read as "no error" below and send an empty write, so a
  # planner that fails is its own <error>, never a silent fall-through.
  plan=$(slacker_edit_list_plan "$rawf" "$umap" "$cmap" "$where" "$expects" "$sets") || plan=""
  rm -f "$umap" "$cmap"
  [ -n "$plan" ] || { rm -f "$rawf"; slacker_error bad_list_payload escalate \
    "list $listid has a shape edit-list cannot plan a write against. Nothing was written." \
    "Read it with: slacker.sh read-list $listid, and tell the user."; return 1; }
  if [ "$(printf '%s' "$plan" | jq -r 'has("error")')" = "true" ]; then
    rm -f "$rawf"
    slacker_error "$(printf '%s' "$plan" | jq -r '.error.code')" \
      "$(printf '%s' "$plan" | jq -r '.error.action')" \
      "$(printf '%s' "$plan" | jq -r '.error.message')" \
      "$(printf '%s' "$plan" | jq -r '.error.next')"
    return 1
  fi
  rm -f "$rawf"

  # A user cell arrives as the name the caller typed. Resolve each one the way
  # send resolves @user, so a miss or an ambiguous name is its own <error>.
  local cells userid raw
  cells=$(printf '%s' "$plan" | jq -c '.cells')
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    userid=$(slacker_resolve_user "$raw" "$users_file") || return 1
    cells=$(jq -cn --argjson c "$cells" --arg raw "$raw" --arg id "$userid" \
      '$c | map(if has("user") and .user == [$raw] then .user = [$id] else . end)')
  done <<EOF
$(printf '%s' "$plan" | jq -r '.cells[] | select(has("user")) | .user[0]')
EOF

  slacker_api slackLists.items.update \
    --data-urlencode "list_id=$listid" \
    --data-urlencode "cells=$cells" > /dev/null || return 1

  slacker_edit_list_readback "$listid" "$(printf '%s' "$plan" | jq -r '.row')" \
    "$(printf '%s' "$plan" | jq -r '.updated')"
}

# slacker_edit_list_plan <listfile> <usersfile> <channelsfile> <where> <expects> <sets>
# Prints {row, updated, cells} for the write, or {error:{code,action,message,next}}.
# Pure: every check that can fail runs here, before anything is written.
slacker_edit_list_plan() {
  # shellcheck disable=SC2016  # a jq program: its $names arrive through --arg.
  jq -cn -L "$SLACKER_ROOT/lib" 'include "render";
    ($list[0] // {}) as $l | ($users[0] // {}) as $u | ($channels[0] // {}) as $c
    | ($l | list_choices) as $choices
    | ($l.list_metadata.schema // []) as $cols
    | ($l.list_records // []) as $rows
    | def fail($code; $action; $message; $next):
        {error: {code: $code, action: $action, message: $message, next: $next}};
      def q: "\u0027" + . + "\u0027";
      # Column, operator, value. The column is the shortest prefix, so a value
      # may itself hold = or ^=. null when the operator is missing or not allowed.
      def parse($ops):
        [ capture("^(?<col>.*?)(?<op>\\^=|=)(?<val>.*)$") ] | .[0]
        | if . == null then null elif (.op as $op | $ops | index($op)) == null then null else . end;
      def column($name):
        first(($cols[] | select(.name == $name)), ($cols[] | select(.key == $name))) // null;
      def cell($row; $col):
        (($row.fields // []) | map(select(.key == $col.key)) | .[0])
        | if . == null then "" else list_cell_text($u; $c; $choices) end;
      def rich($v):
        [{type: "rich_text", elements: [{type: "rich_text_section", elements: [{type: "text", text: $v}]}]}];
      # One --set as a cell, or as {bad} naming why it cannot be one.
      def encode($col; $v):
        if   $col.type == "text" then {rich_text: rich($v)}
        elif $col.type == "user" then {user: [$v]}
        elif $col.type == "date" then
          (if ($v | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then {date: [$v]} else {bad: "date"} end)
        elif $col.type == "select" then
          ([ ($col.options.choices // [])[] | select(.label == $v or .value == $v) | .value ] | .[0])
          | if . == null then {bad: "option"} else {select: [.]} end
        else {bad: "type"} end;

      ($where | parse(["=", "^="])) as $w
    | [ $sets[]    | parse(["="]) ] as $s
    | [ $expects[] | parse(["="]) ] as $e
    | def unknown_column:
        first([ $w.col, ($s[] | .col), ($e[] | .col) ][] | select(column(.) == null)) // null;
      def hits: [ $rows[] | select(cell(.; column($w.col)) as $t
                  | if $w.op == "=" then $t == $w.val else ($t | startswith($w.val)) end) ];
      def row: hits[0];
      def changed: first($e[] | column(.col) as $ec
                   | select(cell(row; $ec) != .val) | . + {now: cell(row; $ec)}) // null;
      def encoded: [ $s[] | column(.col) as $sc | encode($sc; .val) + {name: .col, type: $sc.type, val: .val} ];
      def bad($kind): first(encoded[] | select(.bad == $kind)) // null;

      # Every check that can fail, in order. The first one that fires is the
      # answer, and nothing after it runs, so a later check may assume the
      # earlier ones passed.
      first(
        ( if $w == null then
            fail("bad_list_filter"; "recover"; "--where " + ($where | q) + " has no = or ^=.";
                 "Write it as Column=value (the whole cell) or Column^=prefix, then retry.")
          elif ($s | index(null)) != null or ($e | index(null)) != null then
            fail("bad_list_filter"; "recover"; "every --set and --expect must be Column=value.";
                 "Fix the argument, then retry.")
          else empty end ),
        ( unknown_column | select(. != null)
          | fail("list_column_not_found"; "recover";
                 "no column named " + q + ". The columns are: " + ([ $cols[] | .name // .key ] | join(", ")) + ".";
                 "Use one of those names, then retry.") ),
        ( hits | select(length == 0)
          | fail("list_row_not_found"; "recover"; "no row where " + $w.col + " " + $w.op + " " + ($w.val | q) + ".";
                 "Read the rows with: slacker.sh read-list <list>, then retry with a --where that matches one row.") ),
        ( hits | select(length > 1)
          | fail("list_row_ambiguous"; "recover";
                 "--where matches " + (length | tostring) + " rows: "
                 + ([ .[] | cell(.; column($w.col)) ] | join("; ")) + ". Nothing was written.";
                 "Narrow --where until it matches one row. Column=value matches the whole cell.") ),
        ( changed | select(. != null)
          | fail("list_cell_changed"; "escalate";
                 .col + " holds " + (.now | q) + ", not the expected " + (.val | q) + ". Nothing was written.";
                 "The row changed since it was read. Tell the user what it holds now, and do not write over it without their say-so.") ),
        ( bad("type") | select(. != null)
          | fail("list_column_unsupported"; "escalate";
                 "column " + (.name | q) + " is a " + .type + " column. edit-list writes text, select, user and date columns.";
                 "Tell the user this column has to be edited in Slack.") ),
        ( bad("option") | select(. != null)
          | fail("list_option_not_found"; "recover";
                 (.val | q) + " is not an option of " + .name + ". The options are: "
                 + ([ (column(.name).options.choices // [])[] | .label // .value ] | join(", ")) + ".";
                 "Use one of those labels, then retry.") ),
        ( bad("date") | select(. != null)
          | fail("bad_date"; "recover"; .name + " takes a date as YYYY-MM-DD, not " + (.val | q) + ".";
                 "Rewrite the date as YYYY-MM-DD, then retry.") ),
        { row: row.id,
          updated: ([ encoded[] | .name ] | unique | join(", ")),
          cells: [ encoded[] | {row_id: row.id, column_id: column(.name).id} + del(.name, .type, .val) ] }
      )
  ' --slurpfile list "$1" --slurpfile users "$2" --slurpfile channels "$3" \
    --arg where "$4" --argjson expects "$5" --argjson sets "$6"
}

# slacker_edit_list_readback <list-id> <row-id> <updated-columns>
# Prints the written row as read-list renders it. The write already happened, so
# a failed read-back is a note on the result, never a failed edit.
slacker_edit_list_readback() {
  local listid="$1" row="$2" updated="$3" rawf note=""
  rawf=$(mktemp "${TMPDIR:-/tmp}/slacker_list.XXXXXX")
  if ! slacker_fetch_list "$listid" "$rawf" 3>/dev/null; then
    note="the write succeeded, but reading the row back failed"
    printf '{}' > "$rawf"
  fi
  local users_file channels_file umap cmap
  users_file=$(slacker_users_cache) || { rm -f "$rawf"; return 1; }
  channels_file=$(slacker_channels_cache) || { rm -f "$rawf"; return 1; }
  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_lumap.XXXXXX")
  slacker_augment_users "$users_file" < "$rawf" > "$umap"
  cmap=$(mktemp "${TMPDIR:-/tmp}/slacker_lcmap.XXXXXX")
  slacker_augment_channels "$channels_file" < "$rawf" > "$cmap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($list[0] // {}) as $l | ($users[0] // {}) as $u | ($channels[0] // {}) as $c
    | ($l | .list_records = [ (.list_records // [])[] | select(.id == $row) ]) as $one
    | (if $note != "" then $note
       elif ($one.list_records | length) == 0 then "the write succeeded, but the row is gone from the read-back"
       else "" end) as $why
    | "<list id=\"" + attr($id) + "\" title=\"" + attr($title)
      + "\" permalink=\"" + attr($perma) + "\" row=\"" + attr($row)
      + "\" updated=\"" + attr($updated) + "\">\n"
    + (if $why != "" then "  <note>" + ($why | xml_escape) + "</note>\n"
       else "  <table>" + (($one | render_list_rows($u; $c; 1)) | xml_escape) + "</table>\n" end)
    + "</list>"
  ' --arg id "$listid" --arg title "$SLACKER_SH_LIST_TITLE" --arg perma "$SLACKER_SH_LIST_PERMALINK" \
    --arg row "$row" --arg updated "$updated" --arg note "$note" \
    --slurpfile list "$rawf" --slurpfile users "$umap" --slurpfile channels "$cmap"
  rm -f "$rawf" "$umap" "$cmap"
}

slacker_edit_list "$@"
