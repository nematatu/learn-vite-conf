# 全ての区間をそのまま維持します。同じ講演の隣接区間だけをまとめます。
def valid_segments($start; $end):
  (.segments | type == "array" and length > 0) and
  all(.segments[];
    (.start | type == "number" and floor == .) and
    (.end | type == "number" and floor == .) and
    .start >= $start and .end <= $end and .start < .end and
    (.kind == "talk" or .kind == "other" or .kind == "unknown") and
    (.key | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.speaker | type == "string" and length > 0) and
    (.title | type == "string" and length > 0) and
    (.evidence | type == "string" and length > 0)) and
  .segments[0].start == $start and .segments[-1].end == $end and
  ([range(1; .segments|length) as $i |
     .segments[$i-1].end == .segments[$i].start] | all);

def merge_segments:
  reduce .[] as $s ([];
    if length > 0 and .[-1].end == $s.start and
       .[-1].key == $s.key and .[-1].speaker == $s.speaker and .[-1].kind == $s.kind
    then .[-1].end=$s.end | .[-1].evidence += " / " + $s.evidence
    else . + [$s] end) |
  map(. + {id: ((.start | tostring) + "-" + .key)});

if $action == "validate" then
  if valid_segments($start; $end) then . else error("時刻・区間被覆・識別情報が不正です") end
elif $action == "merge" then [.[].segments[]] | sort_by(.start) | merge_segments
else error("不明な操作") end
