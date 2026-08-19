# lib/render.jq — resolve + render. The denormalization layer.
# Turns raw Slack message JSON into resolved XML: IDs become names, mentions
# become readable, timestamps become human, shares/reactions/files inlined.
# Included by actions via: jq -L lib 'include "render"; ...'

def xml_escape:
  if . == null then ""
  else tostring
    | gsub("[\\x{00}-\\x{08}\\x{0B}\\x{0C}\\x{0E}-\\x{1F}]"; "")
    | gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
    | gsub("\""; "&quot;")
  end;

def attr($v): ($v | xml_escape);

# Users map entries are objects {n,r,h,d}. These helpers read them null-safely
# (jq throws on $map[null], and tolerate a legacy string map just in case).
def user_name($users; $id):
  ($users[($id // "")] | if type == "object" then .n elif type == "string" then . else null end);
def user_deleted($users; $id):
  ($users[($id // "")] | (if type == "object" then .d else false end) // false);

# Decode Slack markup: user/channel mentions, group mentions, links, broadcasts.
def resolve_text($users; $channels):
  if . == null then ""
  else .
    | gsub("<@(?<id>[A-Z0-9]+)(\\|[^>]*)?>"; "@" + (user_name($users; .id) // .id))
    | gsub("<#(?<id>[A-Z0-9]+)\\|(?<nm>[^>]*)>"; "#" + (if .nm != "" then .nm else ($channels[.id] // .id) end))
    | gsub("<#(?<id>[A-Z0-9]+)>"; "#" + ($channels[.id] // .id))
    | gsub("<!subteam\\^[A-Z0-9]+(\\|(?<nm>[^>]*))?>"; ("@" + (.nm // "group")))
    | gsub("<!(?<k>here|channel|everyone)>"; "@" + .k)
    | gsub("<(?<u>[a-zA-Z][a-zA-Z0-9+.-]*:[^|>]+)\\|(?<t>[^>]*)>"; .t + " (" + .u + ")")
    | gsub("<(?<u>[a-zA-Z][a-zA-Z0-9+.-]*:[^>]+)>"; .u)
    # Slack pre-encodes literal & < > in message text. Decode them here so the
    # caller's xml_escape encodes exactly once (avoids &amp;gt;).
    | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&")
  end;

def hex2int:
  explode | reduce .[] as $c (0;
    . * 16 + (if $c >= 48 and $c <= 57 then $c - 48
              elif $c >= 97 and $c <= 102 then $c - 87
              elif $c >= 65 and $c <= 70 then $c - 55
              else 0 end));

# Canvas content comes back as quip HTML. Reduce it to readable markdown-ish
# text: headings, bullets, line breaks, entity decode. jq-only (oniguruma gsub).
def html_to_text:
  gsub("<li[^>]*>"; "\n- ")
  | gsub("<h1[^>]*>"; "\n# ") | gsub("<h2[^>]*>"; "\n## ") | gsub("<h3[^>]*>"; "\n### ")
  | gsub("</(h[1-6]|p|div|li)>"; "\n")
  | gsub("<br[^>]*>"; "\n")
  | gsub("<[^>]+>"; "")
  | gsub("&#[xX](?<h>[0-9a-fA-F]+);"; ([.h | hex2int] | implode))
  | gsub("&#(?<d>[0-9]+);"; ([.d | tonumber] | implode))
  | gsub("&amp;"; "&") | gsub("&lt;"; "<") | gsub("&gt;"; ">")
  | gsub("&quot;"; "\"") | gsub("&#39;"; "'") | gsub("&nbsp;"; " ")
  | gsub("\n{3,}"; "\n\n")
  | gsub("^\n+"; "");

def fmt_ts:
  if . == null or . == "" then ""
  else (tostring | split(".")[0] | tonumber | localtime | strftime("%Y-%m-%d %H:%M"))
  end;

def author_name($users):
  (user_name($users; .user) // .user // .username // .bot_profile.name // .bot_id // "unknown");

# A search match's channel can surface as a real name, or (for DMs) as the
# counterpart's user id in either .name or the cache. Resolve the id to dm:Name.
def channel_label($users; $channels):
  ((.channel.name // $channels[.channel.id // ""] // .channel.id // "")) as $raw
  | if ($raw | test("^[UW][A-Z0-9]+$")) then "dm:" + (user_name($users; $raw) // $raw) else $raw end;

# Many app/bot messages put content in blocks (rich_text), not .text. Derive a
# readable text fallback from blocks (and attachment text) so they don't render blank.
def blocks_to_text($users; $channels):
  def el:
    if   .type == "text"      then (.text // "")
    elif .type == "link"      then ((.text // "") as $t | (.url // "") as $u
                                     | if $t == "" or $t == $u then $u else $t + " (" + $u + ")" end)
    elif .type == "user"      then "@" + (user_name($users; .user_id) // .user_id)
    elif .type == "usergroup" then "@group"
    elif .type == "channel"   then "#" + ($channels[.channel_id // ""] // .channel_id // "")
    elif .type == "broadcast" then "@" + (.range // "here")
    elif .type == "emoji"     then ":" + (.name // "") + ":"
    else (.text // "") end;
  def section: ((.elements // []) | map(el) | join(""));
  ([ (.blocks // [])[]
     | if .type == "rich_text" then
         ((.elements // []) | map(
            if   .type == "rich_text_section"      then section
            elif .type == "rich_text_list"         then
              (((.indent // 0) | if . > 0 then ("  " * .) else "" end) as $pad
               | (.elements // []) | map($pad + "• " + section) | join("\n"))
            elif .type == "rich_text_quote"        then ("> " + section)
            elif .type == "rich_text_preformatted" then section
            else "" end) | join("\n"))
       elif .type == "section" then ((.text.text // "") | resolve_text($users; $channels))
       else "" end ]
   + [ (.attachments // [])[]
       | [ (.pretext // ""), (.title // ""), (.text // ""), (.fallback // "") ]
         | reduce .[] as $x ([]; if ($x | length) > 0 and ((map(. == $x) | any) | not) then . + [$x] else . end)
         | join("\n") | resolve_text($users; $channels) ])
  | map(select(. != "")) | join("\n")
  # Sections carry their own trailing newline, so joining them stacks blank runs.
  | gsub("\n{3,}"; "\n\n");

# `.text` is a sender-supplied fallback, not the message. An app that hand-builds
# rich_text blocks often writes a flattened one: every newline becomes a space and
# the list items merge into one paragraph, so a reader cannot see the structure the
# blocks do carry. Detect that exact shape: the blocks hold a list or several
# sections, while .text has no line break at all. Then render from the blocks
# instead. Everything else keeps .text, whose Slack-generated mrkdwn carries the
# bold and italic that the blocks walker drops.
def text_is_flattened:
  ((.text // "") | contains("\n") | not)
  and ([ (.blocks // [])[] | select(.type == "rich_text") | (.elements // [])[] ] as $els
       | (($els | map(select(.type == "rich_text_list")) | length) > 0)
         or (($els | map(select(.type == "rich_text_section")) | length) > 1));

# Best available text for a message: .text, unless it is empty or flattened.
def message_text($users; $channels):
  if (.text // "") == "" or text_is_flattened
  then blocks_to_text($users; $channels)
  else (.text | resolve_text($users; $channels)) end;

def render_reactions($users):
  if ((.reactions // []) | length) == 0 then ""
  else "    <reactions>\n"
    + ([ .reactions[]
         | "      <reaction emoji=\"" + attr(.name) + "\" count=\"" + (.count | tostring)
           + "\" by=\"" + (((.users // []) | map(user_name($users; .) // .) | join(", ")) | xml_escape) + "\"/>\n"
       ] | add)
    + "    </reactions>\n"
  end;

def render_files:
  if ((.files // []) | length) == 0 then ""
  else "    <files>\n"
    + ([ .files[]
         | if .mode == "tombstone"
           then "      <file id=\"" + attr(.id) + "\" deleted=\"true\"/>\n"
           else "      <file name=\"" + attr(.name) + "\" type=\"" + attr(.filetype)
                + "\" size=\"" + ((.size // 0) | tostring) + "\" url=\"" + attr(.url_private) + "\"/>\n"
           end
       ] | add)
    + "    </files>\n"
  end;

# Forwarded / shared messages arrive as attachments. Render the original inline.
def render_forwards($users; $channels):
  ([ (.attachments // [])[]
     | select((.is_share == true) or (.is_msg_unfurl == true) or (.message_blocks != null)) ]) as $shares
  | if ($shares | length) == 0 then ""
    else ([ $shares[]
            | "    <forward from=\"" + attr(user_name($users; .author_id) // .author_subname // .author_name // "")
              + "\" channel=\"" + attr(.channel_name // ($channels[.channel_id // ""] // ""))
              + "\" time=\"" + ((.ts // "") | fmt_ts) + "\">"
              + ((.text // "") | resolve_text($users; $channels) | xml_escape)
              + "</forward>\n"
          ] | add)
  end;

# Interactive block-kit that carries no readable text: action buttons, context
# lines, inputs, images, headers, dividers, and section accessories. Rendered
# only when present — plain rich_text/section text stays in message_text. A
# retired suggestion card arrives as a context block ("✓ <label>"), so tapped
# state renders for free.
def render_block_meta($users; $channels):
  def btn_label($t): (($t // "") | resolve_text($users; $channels));
  def action_el:
    if   .type == "button"     then "      <button action_id=\"" + attr(.action_id) + "\" label=\"" + attr(btn_label(.text.text)) + "\"/>\n"
    elif .type == "overflow"   then ([ (.options // [])[]
          | "      <option action_id=\"" + attr(.action_id) + "\" label=\"" + attr(btn_label(.text.text)) + "\"/>\n" ] | add)
    elif .type == "datepicker" then "      <picker action_id=\"" + attr(.action_id) + "\" label=\"" + attr(btn_label(.initial_date // "")) + "\"/>\n"
    elif .type == "image"      then "      <image url=\"" + attr(.image_url) + "\" alt=\"" + attr(.alt_text) + "\"/>\n"
    else "" end;
  def block_el:
    if   .type == "actions" then ([ (.elements // [])[] | action_el ] | add)
    elif .type == "context" then
      "      <context text=\"" + attr(((.elements // []) | map((.text // "") | resolve_text($users; $channels)) | join(" "))) + "\"/>\n"
    elif .type == "input" then
      "      <input label=\"" + attr((.label.text // "")) + "\" placeholder=\"" + attr((.element.placeholder.text // "")) + "\" optional=\"" + ((.optional // false) | tostring) + "\"/>\n"
    elif .type == "header" then "      <header text=\"" + attr((.text.text // "")) + "\"/>\n"
    elif .type == "divider" then "      <divider/>\n"
    elif .type == "image" then "      <image url=\"" + attr(.image_url) + "\" alt=\"" + attr(.alt_text) + "\"/>\n"
    elif .type == "section" then (.accessory | action_el)
    else "" end;
  ([ (.blocks // [])[] | block_el | select(. != "") ] | add) as $inner
  | if ($inner // "") == "" then "" else "    <blocks>\n" + $inner + "    </blocks>\n" end;

# $target: ts of the message the caller pointed at; gets target="true" ("" = none).
# A {slacker_more:true} sentinel renders a truncation marker instead of a reply.
def render_reply($users; $channels; $target):
  if .slacker_more == true then "      <more note=\"more replies in this thread; raise --reply-cap or open it\"/>\n"
  else
  "      <reply author=\"" + attr(author_name($users)) + "\" time=\"" + (.ts | fmt_ts)
  + "\" ts=\"" + attr(.ts) + "\""
  + (if (.subtype == "bot_message") or ((.bot_id // null) != null and (.user // "") == "") then " bot=\"true\"" else "" end)
  + (if user_deleted($users; .user) then " deactivated=\"true\"" else "" end)
  + (if .ts == $target then " target=\"true\"" else "" end) + ">\n"
  + "        <text>" + (message_text($users; $channels) | xml_escape) + "</text>\n"
  + render_block_meta($users; $channels)
  + render_reactions($users)
  + render_files
  + render_forwards($users; $channels)
  + "      </reply>\n"
  end;

def render_msg($users; $channels; $threads; $target):
  "  <message author=\"" + attr(author_name($users)) + "\" id=\"" + attr(.user // .bot_id // "")
  + "\" time=\"" + (.ts | fmt_ts) + "\" ts=\"" + attr(.ts) + "\""
  + (if (.subtype == "bot_message") or ((.bot_id // null) != null and (.user // "") == "") then " bot=\"true\"" else "" end)
  + (if .edited then " edited=\"true\"" else "" end)
  + (if user_deleted($users; .user) then " deactivated=\"true\"" else "" end)
  + (if (.reply_count // 0) > 0 then " replies=\"" + ((.reply_count) | tostring) + "\"" else "" end)
  + (if .ts == $target then " target=\"true\"" else "" end) + ">\n"
  + "    <text>" + (message_text($users; $channels) | xml_escape) + "</text>\n"
  + render_block_meta($users; $channels)
  + render_reactions($users)
  + render_files
  + render_forwards($users; $channels)
  + (if (($threads[.ts] // []) | length) > 0
     then "    <thread>\n" + ([ $threads[.ts][] | render_reply($users; $channels; $target) ] | add) + "    </thread>\n"
     else "" end)
  + "  </message>\n";
