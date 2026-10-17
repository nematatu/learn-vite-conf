# ViteConf 2026 日本語学習ノート

ViteConf 2026の映像・音声から、スライド、コード、図表、ライブデモと発言の関係を詳しく読み解くための、個人による非公式の学習リポジトリです。**ViteConfの公式プロジェクトではありません。**

英語の長時間カンファレンスを短い要約だけで済ませず、React・TypeScriptなどの開発経験がある方が、技術の仕組みや設計判断まで日本語で学べる資料を蓄積します。生成の条件とプロンプトも公開し、後から検証・再生成できるようにします。

- [元動画（依頼で指定されたYouTubeアーカイブ）](https://www.youtube.com/watch?v=PfyIEgLzNYI)
- [ViteConf公式スケジュール](https://www.viteconf.org/schedule)
- [学習ノートと生成状況](notes/README.md)
- [目的・範囲](docs/project-goals.md)／[解析手法と制約](docs/methodology.md)／[公式資料の確認記録](docs/references.md)
- [次に進める作業](docs/next-steps.md)

## 現在の状態

2026-10-17時点で、生成・送信・抽出スクリプトとリクエストJSONを用意しています。**今回の30分解析は未実行**です。実行環境にGemini APIキーがなく、解析レポート・実測トークン数はまだありません。未生成のレポートファイルや架空の登壇別ノートは掲載していません。

以前の20秒テストについては[利用者からの報告](docs/experiments/2026-10-17-20s-smoke-test.md)として保存しています。このリポジトリでの再現実行や元映像との照合を済ませたものではありません。

## 解析する内容

最初の実行対象は元動画の **0〜1800秒（00:00〜30:00）**、モデルは `gemini-3.8-flash` です。GenerateContent APIへYouTube URLを直接渡し、`fileData` と `videoMetadata.startOffset` / `endOffset` で入力区間を制限します。既定のStatic処理を使い、Agenticへの切り替えは行いません。

音声の文字起こしだけでは、画面にしか出ないコード、型、CLI、アーキテクチャ図、ベンチマーク条件を取り落とします。[解析プロンプト全文](prompts/gemini-talk-analysis.md)で、映像・音声の対応、確認根拠、元動画の時刻、不明点を含む詳細なMarkdownを求めています。

公式スケジュールにはWelcome、Evan Youの「Developer Tooling in the Agentic Era」、Christoph Nakazawaの「Deploy to Void」がこの順で掲載されています。ただし、配信予定時刻とアーカイブ内の秒数は同じものではありません。登壇の境界は映像で確認するまで不明です。30分全体をEvan Youの発言として扱いません。

## 再現方法

必要なものはBash 3.2以上、curl、jq、shasum、Gitです。公開時には認証済みのGitHub CLIも使用します。実装にNode.js、Python、Webアプリ、サーバーは不要です。

```bash
git clone https://github.com/nematatu/learn-vite-conf.git
cd learn-vite-conf
bash scripts/build-request.sh
bash scripts/run-first-30m.sh --dry-run
```

`config/viteconf-2026.json` が動画URL・モデル・区間・出力上限の定義、`prompts/gemini-talk-analysis.md` がプロンプトの唯一の原本です。`jq --rawfile` で原文を安全に読み込み、`requests/first-30m.json` を生成します。生成スクリプトとドライランはAPI通信もキー入力も行いません。カレントディレクトリに依存せず実行できます。

実送信は、ご自身のターミナルで次を実行してください。

```bash
bash scripts/run-first-30m.sh
```

環境変数 `GEMINI_API_KEY` がなければ、ターミナルの非表示入力でキーをお尋ねします。**キーをチャットへ貼る必要はありません。** すでに設定している環境変数も使用できます。キーはファイル・URL・curlの引数へ入れず、標準入力のヘッダー設定で渡します。`.env` は自動読み込みしません。スクリプトを `source` せず、上記のようにBashで実行してください。

動画・モデル・区間を表示した後、同期のPOSTを**1回だけ**送ります。自動リトライ、出力の自動継続、次の登壇の解析は行いません。請求設定や有料枠の変更も行いません。APIの利用可否・割当・請求状態は未確認で、Google AIの個人向け購読からAPI利用条件を判断しません。

処理中はターミナルを開いたままにしてください。クライアント側の接続待ちは最大20分、接続確立は最大30秒です。サーバーが先に切断する可能性もあります。非同期ジョブではなく、端末の切断・スリープ・プロセス終了後の完了や復旧は保証しません。タイムアウト時にもサーバーが処理を継続した可能性があるため、まずローカルの記録を確認してください。

## レスポンスと学習資料

実行時のデータは、Git対象外の次の場所へ保存します。

| 場所 | 内容 |
| --- | --- |
| `.local/responses/first-30m.json` | 最新の生レスポンス |
| `.local/logs/first-30m-run.json` | 最新の実行日時・HTTP・curlの終了状態 |
| `.local/logs/first-30m-curl.stderr` | 最新の通信エラー。自動でコンソール出力しません |
| `.local/runs/<実行ID>/` | 各回のリクエスト・設定・プロンプト・生レスポンス・ログ |
| `.local/reports/` | 抽出用メタデータ、不完全な応答の本文 |

HTTP 200、curl終了0、エラーなし、候補1件、`finishReason: STOP`、空白以外の本文あり、を満たすと、実行スクリプトが次を自動生成します。

- `notes/first-30-minutes.md`：本文を省略せず抽出したMarkdown。「AI生成・未照合」の注記付きです。
- `notes/first-30-minutes.metadata.json`：実行日時（UTC）、モデル、区間、HTTP、終了理由、トークン数、リクエスト・プロンプトのSHA-256、検証状況。

未返却のトークン数は `null`（不明）です。動画入力トークン数には `usageMetadata.promptTokensDetails` の `VIDEO` のみを用い、音声を含む動画全体の消費量とは同一視しません。思考テキストと `thoughtSignature` はノートへ混ぜません。

保存済みレスポンスから、APIに再接続せず抽出し直す場合：

```bash
bash scripts/extract-report.sh
```

`MAX_TOKENS`、`CONTINUATION`、空本文、ブロック、通信・APIエラーは完全な応答と扱いません。本文があれば `.local/reports/first-30m.incomplete.md` に残し、公開用ノートは更新せず異常終了します。JSONとして読めない場合は生レスポンスとログを保持します。

再送には `--rerun` を明示する必要があります。以前の `.local/runs/` は残ります。中断後に `.local/first-30m.lock` が残った場合は、別の実行がないことを確認してからその空ディレクトリを `rmdir .local/first-30m.lock` で削除してください。再送は追加のAPI利用になります。

## 品質確認と公開

`STOP` は生成の終了を表す条件であり、内容の正しさを保証しません。本文の「確認済み」はモデルの自己申告です。人による確認済みの事実と混同せず、[検証票](docs/quality-review.md)で話者・境界、スライド、コード、数値、引用を元映像と照合します。通常のフレーム抽出では短い表示や細かいコードを取り逃す可能性があります。

`videoMetadata` は[APIリファレンス](https://ai.google.dev/api/generate-content#VideoMetadata)で非推奨です。今回の成功報告がある方式を維持し、将来の移行は公式仕様と短区間の動作を確認してから別の手法バージョンとして記録します。

生成後のコミット・pushは自動化していません。未検証の本文や転載範囲をレビューし、Evan Youの講演境界が確認できたら `notes/talks/evan-you-developer-tooling-in-the-agentic-era.md` を作成します。その段階でノート索引とREADMEの状態を更新し、対象ファイルだけを明示してコミットしてください。詳細は[次の作業](docs/next-steps.md)をご覧ください。

オフラインの検証（実API・本物のキーは使用しません）：

```bash
bash tests/offline.sh
```

初期実装で実施した検証は[検証記録](docs/experiments/2026-10-17-offline-validation.md)に掲載しています。

## 出典・権利

元動画・登壇内容の提供者であるViteConf主催者、登壇者、関連プロジェクトに感謝いたします。映像・音声・スライド・コードなどの第三者の権利は各権利者に帰属します。動画本体、全文の書き起こし、スライドの大量複製を公開する目的ではありません。独自の日本語解説を中心とし、必要な引用には出典と時刻を付します。

リポジトリ全体への一律のライセンスは設定していません。[ライセンス方針](LICENSE-POLICY.md)をご確認ください。
