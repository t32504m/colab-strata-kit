# CLAUDE.md に置く短い版

監督（Opus）が使うプロジェクトの CLAUDE.md に、次の節をそのまま貼る。G:\local\CLAUDE.md には貼ってある。

```
## 委譲（Opus = 監督、Colab の Qwen3.8 = ワーカー）
- 手順・前提・API の直接利用・つまずきやすい所は G:\local\delegation\HANDOFF.md にまとめてある（Colab の Qwen3.8 を使う前に読む）。
- 任せるのは「知能の高い LLM がやらなくてよい仕事」: 量・繰り返し・読む量が多い、何度も回す仕事。判断・設計・ユーザーとのやりとりは任せない。
- 作業の前に G:\local\delegation\docs\AGENT.md の「判断」で振り分け、台帳 G:\local\delegation\ledger.md に理由を1行書く。
  目安: 結果をすぐ使うものは任せない。出力や読む量がカードの10倍以上なら任せる。数行の修正は自分でやる。
- 渡すのは delegate.ps1 経由だけ（run -Async か queue）。渡したら待たずに自分の仕事を続ける。
- コードの仕事には受け入れテスト（ワーカーに見せない）を付けて precheck で落ち方を確かめ、調査の仕事には check_report.py で形を判定させる。
- 結果は report.md と、テストの削除行・受け入れテストが届かない部分だけ確かめる。ワーカーの自己申告は根拠にしない。差し戻しは2回まで。
- 要約の後と新しいセッションの最初は、AGENT.md、台帳の末尾20行、delegate.ps1 status を見直す。台帳の直近10件が一方に偏っていたら見直す。
```
