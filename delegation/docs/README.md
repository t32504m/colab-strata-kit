# 委譲の仕組み（Opus 5.5 = 監督、Colab Strata の Qwen3.8 = ワーカー、DeepSeek Harness = ハーネス）

知能の高い LLM（監督）がやらなくてよい仕事を、Colab で動かしている Qwen3.8 に任せる仕組み。
監督の使用量（トークン）を、判断・設計・レビューに集中させるのが目的。

**ほかのセッションに渡すのは [../HANDOFF.md](../HANDOFF.md) だけでよい**（前提・委譲の手順・API の直接利用・つまずきやすい所を1枚にまとめた入口）。

| ファイル | 内容 |
|---|---|
| [AGENT.md](AGENT.md) | 監督向けの手引き（任せる判断、流れ、受け入れテスト、コマンド、状態の意味） |
| [CLAUDE-snippet.md](CLAUDE-snippet.md) | CLAUDE.md に貼る短い版 |
| [PROMPTS.md](PROMPTS.md) | ユーザーが監督に渡すプロンプト、監督が使う雛形、ワーカーに渡るもの |
| [CARD-EXAMPLES.md](CARD-EXAMPLES.md) | カードの例（アセットの棚卸し、BGM・SE の調査、総当たり、受け入れテスト付きのコード） |
| [TRIAL-2026-11-08.md](TRIAL-2026-11-08.md) | 試験の記録と、そこから入れた改善 |

本体:
- `..\delegate.ps1` — run / followup / adopt / discard / status / queue / wait（`..\delegate.cmd` から呼ぶ）
- `..\worker.patch.yml` — ワーカーの初期指示（dsh の system prompt）
- `..\tools\check_report.py` — 調査レポートの形（見出し・表・根拠の列）を判定する
- `..\accept\` — 監督が書く受け入れテスト（ワーカーには見せない）
- `..\queue\` — まとめて流すカードの置き場
- `..\ledger.md` — 台帳（振り分けの理由と結果）
- `..\runs\` — 実行ごとの記録（git の管理外）

前提: Colab Manager（`G:\local\colab-manager`）で Strata が動いていること。止まっていれば delegate.ps1 が起動を頼んで待つ（約9分）。
