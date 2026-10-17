# 一次情報と検証範囲

確認日：2026-10-17（日本時間）。以下は公開ドキュメントを確認した記録です。サービスへの実API送信や元動画の視聴を済ませたことは意味しません。

| 一次情報 | 確認できた内容・採用箇所 | 未確認・制約 |
| --- | --- | --- |
| [Gemini 3.8 Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash) | モデルコード、動画入力対応、入力上限1,048,576、モデル出力上限65,536 | 個別プロジェクトの利用可否・割当は不明 |
| [GenerateContent動画ガイド](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding) | YouTube URL、Static既定、通常1 FPS、`fileData`と`videoMetadata`を同一Partに指定する区間例。今回の方式に採用 | サンプリングでは全画面の文字判読を保証しません。30分の今回条件は未実行 |
| [GenerateContent API reference](https://ai.google.dev/api/generate-content#VideoMetadata) | `VideoMetadata`は非推奨、代替として `GenerateContentRequest.processing_options` が案内されています。開始・終了は秒数と末尾sのDuration文字列 | 非推奨を理由とする自動移行は実施しません |
| [GenerateContent tokens](https://ai.google.dev/gemini-api/docs/generate-content/tokens) | Gemini 3は入力1,048,576と出力65,536が別予算、Gemini 4は共有予算で非ストリーミング32,768との区別 | 推計から今回の実測トークン数を作成しません |
| [Gemini 4への変更点：出力上限の世代差](https://ai.google.dev/gemini-api/docs/generate-content/latest-model?hl=en) | 非ストリーミングの上限がGemini 3.xの65,536からGemini 4の32,768へ変わったとの説明 | Gemini 4の上限を3.8の仕様として扱いません。今回は依頼の初期値に沿い、モデル上限より低い32,768を初回の出力予算として採用。30分の詳細説明を収められるかは実行後に評価 |
| [GenerateContent long decode](https://ai.google.dev/gemini-api/docs/generate-content/long-decode) | 32,768等の継続処理の説明を検索結果で確認 | 本文直接取得は失敗。モデル世代の区別には上記の直接取得できた資料を使用。継続処理は今回実装しません |
| [ViteConf公式スケジュール](https://www.viteconf.org/schedule) | Welcome（3分）、Evan You / Developer Tooling in the Agentic Era（25分）、Christoph Nakazawa / Deploy to Void（10分）の順。時刻は概算との注記 | アーカイブ上の0:00、3:00、28:00との一致は不明 |
| [ViteConf公式配信ページ](https://www.viteconf.org/live) | 公式サイトに配信ページが存在すること | アーカイブ全編の時間軸は確認していません |
| [対象YouTube動画](https://www.youtube.com/watch?v=PfyIEgLzNYI) | 利用者が指定した解析対象URLとして設定 | 閲覧ツールでの直接取得に失敗。タイトル、長さ、話者、実スライド、公開状態の再確認は未完了 |

## 利用者提供の証跡

[20秒テストの報告](experiments/2026-10-17-20s-smoke-test.md)は利用者からいただいた情報です。生レスポンスやAPI実行ログによる独立確認はしていません。

## 仕様を再確認する際の判断

GenerateContent向けのパスを使用し、Interactions API向け資料の設定をそのまま転用しません。今回のリクエストは出力予算32,768に留めます。これはモデル仕様上の最大値という意味ではありません。`videoMetadata`の廃止、既定処理の変更、モデル利用不可などのエラーが出ても、モデル・方式を自動変更しません。公式資料と短区間の動作確認に基づく変更を別途記録します。
