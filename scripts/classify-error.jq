# GenerateContentの応答から原因と処理方針を決定します。曖昧な429等を推測で細分化しません。
def text: if type == "string" then . else "" end;
def array: if type == "array" then . else [] end;
def object: if type == "object" then . else {} end;
def clean: text | gsub("[\\x00-\\x1f\\x7f]"; " ") |
  gsub("AIza[A-Za-z0-9_-]{20,}"; "[REDACTED]") |
  gsub("(?i)(key|api_key|token)=[^ &]+"; "credential=[REDACTED]") | .[0:2000];
def issue($category; $summary; $action; $stop; $basis):
  {category:$category,summary:$summary,action:$action,stopRun:$stop,basis:$basis};

. as $r |
($r.error | object) as $error |
($error.message | text) as $message |
($error.status | text) as $status |
($error.details | array) as $details |
[$details[] | object | select(."@type" == "type.googleapis.com/google.rpc.ErrorInfo") | .reason | text] as $reasons |
[$details[] | object | select(."@type" == "type.googleapis.com/google.rpc.QuotaFailure") |
  .violations | array | .[] | object |
  {quotaId:(.quotaId|text),quotaMetric:(.quotaMetric|text),description:(.description|clean),quotaValue:.quotaValue}] as $quotas |
([$details[] | object | select(."@type" == "type.googleapis.com/google.rpc.RetryInfo") |
  .retryDelay | text | select(test("^[0-9]+(\\.[0-9]+)?s$"))] | first // null) as $retry |
([$reasons[], $quotas[] | if type=="object" then (.quotaId + " " + .quotaMetric + " " + .description) else . end] | join(" ")) as $limits |
($r.candidates | array) as $candidates |
($candidates[0] | object) as $candidate |
($candidate.finishReason | text) as $finish |
($r.promptFeedback | object | .blockReason | text) as $block |
($context.curlExit // 0) as $curl |
($context.httpStatus // 0) as $http |
(
  if $localCategory != "" then
    if $localCategory == "invalid_timeline" then
      issue("invalid_timeline"; "登壇識別JSONの形式、時刻の範囲、区間の連続性が不正です。";
        "対象区間の識別結果を確認し、修正後に同じコマンドで再実行してください。後続の詳細解析は未実行です。"; true; "local_validation")
    elif $localCategory == "speaker_not_found" then
      issue("speaker_not_found"; "テスト範囲で対象の登壇者を識別できませんでした。";
        "timeline-test.jsonの氏名と対象範囲を確認してください。他の話者を対象者として処理せず停止します。"; true; "local_validation")
    elif $localCategory == "source_metadata" then
      issue("source_metadata"; "動画情報の取得または再生時間の検証に失敗しました。";
        "取得ログと動画の公開状態・通信環境を確認してください。Geminiへの送信は行っていません。"; true; "local_validation")
    elif $localCategory == "schedule_fetch" then
      issue("schedule_fetch"; "公式スケジュールの取得に失敗しました。";
        "HTTP・curlの詳細と公式URLを確認してください。Geminiへの送信は行っていません。"; true; "local_validation")
    elif $localCategory == "publication_failed" then
      issue("publication_failed"; "生成物のGitHub反映に失敗しました。学習資料はローカルに保存済みです。";
        "表示されたGitエラーと認証・作業ツリーを確認してください。Gemini解析を再送せず、Gitの失敗した操作だけを再実行できます。"; true; "local_validation")
    else issue($localCategory; "ローカル処理が失敗しました。"; "記録を確認してください。"; true; "local_validation") end
  elif $curl != 0 then
    if $curl == 28 then
      issue("network_timeout"; "通信の待ち時間を超過しました。";
        "通信ログを確認してください。サーバー側の処理完了は不明です。再送すると重複利用になる可能性があります。"; false; "curl_exit")
    elif ($curl == 5 or $curl == 6) then
      issue("dns_error"; "ホストまたはプロキシの名前解決に失敗しました。";
        "DNS・ネットワーク・プロキシ設定を確認してから再実行してください。"; true; "curl_exit")
    elif $curl == 7 then
      issue("connection_failed"; "接続先との接続を確立できませんでした。";
        "ネットワーク・プロキシ・接続先の稼働状態を確認してください。"; true; "curl_exit")
    elif ([35,51,58,60,77] | index($curl)) != null then
      issue("tls_error"; "TLS接続または証明書の検証に失敗しました。";
        "証明書・プロキシ・端末時計と通信ログを確認してください。証明書検証を無効化して再送しないでください。"; true; "curl_exit")
    elif ($curl == 23 or $curl == 26) then
      issue("local_io_error"; "ローカルファイルの読み書きに失敗しました。";
        "ディスク空き容量・権限と通信ログを確認してください。"; true; "curl_exit")
    else issue("transport_error"; "通信処理が失敗しました。詳細な原因は不明です。";
      "curl終了コードと通信ログを確認してください。送信済みの場合、再送は重複利用になる可能性があります。"; true; "curl_exit") end
  elif $r.error != null or $http != 200 then
    # 構造化されたErrorInfo/QuotaFailureをメッセージの文字列判定より優先します。
    if any($reasons[]; test("^API_KEY_(INVALID|EXPIRED)$")) or $status == "UNAUTHENTICATED" or $http == 401 then
      issue("authentication"; "APIキーの認証に失敗しました。";
        "キーの有効性・有効期限を確認し、修正したキーで再実行してください。キーをチャットへ貼る必要はありません。"; true; "api_status_or_reason")
    elif any($reasons[]; test("^(API_KEY_.*BLOCKED|SERVICE_DISABLED|ACCESS_TOKEN_SCOPE_INSUFFICIENT)$")) or $status == "PERMISSION_DENIED" or $http == 403 then
      issue("permission_denied"; "APIまたは対象リソースへのアクセスが拒否されました。";
        "返却された理由とAPIキーの制限・API有効化・対象へのアクセス権を確認してください。"; true; "api_status_or_reason")
    elif $http == 402 then
      issue("billing_required"; "支払いに関するエラーが返されました。";
        "返却されたメッセージと契約・残高の状態を確認してください。請求設定は自動変更しません。"; true; "http_status")
    elif any($quotas[]; (.quotaValue|tostring)=="0") then
      issue("quota_unavailable"; "返却された利用枠の上限が0です。待機だけで解消するかは不明です。";
        "該当するquotaId・quotaMetricとプロジェクトの利用資格・割当を確認してください。有料化は自動で行いません。"; true; "quota_details")
    elif $limits | test("per.?day|daily"; "i") then
      issue("daily_quota"; "日単位の利用枠に関する超過が返されました。";
        "該当する日次割当とリセット時刻を確認してください。短時間の連続再送は行いません。"; true; "quota_details")
    elif $limits | test("per.?minute|per.?second|RATE_LIMIT_EXCEEDED"; "i") then
      issue("rate_limit"; "短時間あたりのリクエスト数またはトークン数の制限に達しました。";
        "返却された待機時間があればそれを確認し、時間を空けて再実行してください。自動再送は行いません。"; true; "quota_details")
    elif $status == "RESOURCE_EXHAUSTED" or $http == 429 then
      issue("resource_exhausted"; "利用枠または処理資源の不足です。応答だけでは日次枠か短時間制限かを特定できません。";
        "返却された割当情報・待機時間とプロジェクトの使用量を確認してください。原因未確定のまま連続再送しません。"; true; "api_status")
    elif $message | test("(input|prompt|context).{0,100}(token|length|window).{0,100}(exceed|too (long|large)|greater than|over (the )?(allowed )?(limit|maximum))|(exceed|too (many|large)|greater than|over).{0,100}(input|prompt|context).{0,100}(token|length|window)"; "i") then
      issue("input_token_limit"; "APIメッセージから、入力トークン数またはコンテキスト長の超過と判断しました。";
        "対象区間を短くするか、付加した入力情報を減らして再生成してください。同じ要求の再送では解消しません。自動分割・再送は行いません。"; false; "message_inference")
    elif $message | test("(video|youtube|file).{0,80}(not found|unavailable|private|not accessible)|((cannot|unable|failed).{0,40}(fetch|access|read|process).{0,40}(video|youtube|file))"; "i") then
      issue("media_unavailable"; "APIメッセージから、入力動画・ファイルへのアクセスまたは処理の失敗と判断しました。";
        "動画URL・公開状態・対象区間と返却メッセージを確認してください。動画へのアクセス成功を前提に解析を進めません。"; true; "message_inference")
    elif $status == "NOT_FOUND" or $http == 404 then
      issue("resource_not_found"; "指定されたリソースが見つからない応答です。モデルか入力素材かは詳細確認が必要です。";
        "返却メッセージとモデルID・APIバージョン・入力URLを確認してください。モデルは自動変更しません。"; true; "api_status")
    elif $status == "FAILED_PRECONDITION" then
      issue("failed_precondition"; "API実行に必要な前提条件を満たしていません。";
        "返却メッセージから該当するプロジェクト・地域・利用条件を確認してください。請求設定は自動変更しません。"; true; "api_status")
    elif $status == "INVALID_ARGUMENT" or $http == 400 then
      issue("invalid_request"; "リクエストの値または形式が拒否されました。トークン超過と断定できる情報はありません。";
        "返却メッセージとBadRequestのフィールド情報を確認し、送信JSONを修正してください。同じ要求を連続再送しません。"; true; "api_status")
    elif $status == "DEADLINE_EXCEEDED" or $http == 504 or $http == 408 then
      issue("server_timeout"; "サーバーまたはゲートウェイがタイムアウトを返しました。";
        "処理完了は不明です。対象区間と応答を確認して再実行を判断してください。重複利用の可能性があります。"; false; "api_status")
    elif $status == "UNAVAILABLE" or $status == "INTERNAL" or $http == 500 or $http == 502 or $http == 503 then
      issue("service_error"; "サーバー側の処理失敗・一時的な利用不可が返されました。詳しい原因は不明です。";
        "返却メッセージとサービス稼働状況を確認し、時間を空けて未完了分を再実行してください。"; false; "api_status")
    else issue("unknown_api_error"; "未分類のAPIエラーです。原因は断定できません。";
      "返却されたステータス・理由・メッセージと送信JSONを確認してください。追加送信は停止します。"; true; "unclassified") end
  elif $context.responseValid != true then
    issue("invalid_response"; "応答がJSONオブジェクトではないか、応答の構造が不正です。";
      "保存された生レスポンスとプロキシ・通信状態を確認してください。生成済みとは扱いません。"; false; "response_validation")
  elif $finish == "MAX_TOKENS" then
    issue("output_token_limit"; "生成が指定のトークン上限で打ち切られました。完成したレポートではありません。";
      "出力上限・思考トークン使用量・対象区間を確認し、必要なら区間を短くして再生成してください。同じ要求を自動再送しません。"; false; "finish_reason")
  elif $finish == "CONTINUATION" then
    issue("continuation_required"; "応答が継続を必要とする状態で終了しました。";
      "本文は未完了です。現在は継続リクエストを自動送信しません。対象区間・出力条件を見直してください。"; false; "finish_reason")
  elif $block != "" or (["SAFETY","RECITATION","BLOCKLIST","PROHIBITED_CONTENT","SPII","IMAGE_SAFETY","IMAGE_PROHIBITED_CONTENT","IMAGE_RECITATION","ESCALATION","PUP_LIMITED_DISABLED"] | index($finish)) != null then
    issue("content_blocked"; "APIが安全性・引用・コンテンツ制限に関するブロックを返しました。";
      "blockReason・finishReason・返却メッセージを確認してください。同じ入力を自動再送せず、不完全な本文を学習資料へ出しません。"; false; "block_or_finish_reason")
  elif ($candidates | length) == 0 then
    issue("missing_candidate"; "生成候補が返されていません。"; "ブロック情報と生レスポンスを確認してください。"; false; "response_validation")
  elif ($candidates | length) != 1 then
    issue("unexpected_candidates"; "想定する1件以外の生成候補が返されました。"; "候補数と送信設定を確認してください。候補を無条件に連結しません。"; false; "response_validation")
  elif $finish != "STOP" then
    issue("unexpected_finish"; "未対応の終了理由で生成が終わりました。原因は断定できません。"; "finishReason・finishMessageと生レスポンスを確認してください。"; false; "finish_reason")
  elif ([$candidate.content.parts[]? | select(.thought != true) | .text? | select(type=="string")] | join("") | test("\\S")) != true then
    issue("empty_output"; "終了理由はSTOPですが、学習資料に使える本文がありません。"; "使用量と生レスポンスを確認してください。思考情報だけでは完成扱いにしません。"; false; "response_validation")
  else issue("unknown_response_error"; "応答の検査に失敗しました。原因は不明です。"; "生レスポンスと検査ログを確認してください。"; true; "unclassified") end
) + {
  phase:$context.phase,talk:$context.talk,start:$context.start,end:$context.end,
  model:$context.model,httpStatus:$http,curlExit:$curl,
  apiStatus:($status|clean),apiCode:$error.code,
  apiMessage:($message|clean),reasons:[$reasons[]|clean],
  quotaViolations:$quotas,retryDelay:$retry,finishReason:($finish|clean),
  finishMessage:($candidate.finishMessage|clean),blockReason:($block|clean),
  fieldViolations:[$details[] | object | select(."@type"=="type.googleapis.com/google.rpc.BadRequest") |
    .fieldViolations | array | .[] | object | {field:(.field|clean),description:(.description|clean)}],
  usage:($r.usageMetadata | object | {promptTokenCount,candidatesTokenCount,thoughtsTokenCount,totalTokenCount})
} | .stopRun = (.stopRun or ($context.phase != "analysis")) |
  walk(if type=="string" then clean else . end)
