"""調査レポート（Markdown）が決めた形になっているかを確かめる。delegate.ps1 の検証コマンドで使う。

使い方:
  python G:\\local\\delegation\\tools\\check_report.py REPORT.md [--heading "## 見出し"]... [--table-columns "列1|列2|..."]
         [--min-rows N] [--evidence] [--min-bytes N]

  --heading        この行（前後の空白は無視）がレポートにあること。何度でも指定できる。
  --table-columns  見出しの行がこの列（| で区切る）で始まる表があること。
  --min-rows       その表のデータ行が N 行以上あること（--table-columns と一緒に使う）。
  --evidence       表のデータ行のうち「根拠」の列（無ければ最後の列）が空、または "-" の行が無いこと。
                   根拠を確かめられなかった行は "未確認: <試したこと>" と書く（空にしない）。
  --min-bytes      ファイルが N バイト以上あること。

終了コード: 0 = 形に合う、1 = 合わない（理由を標準エラーに出す）、2 = 使い方の誤り。
"""
import argparse
import sys
from pathlib import Path


def cells(line):
    s = line.strip()
    if not (s.startswith("|") and s.endswith("|")):
        return None
    return [c.strip() for c in s[1:-1].split("|")]


def find_table(lines, columns):
    """columns で始まる見出し行を持つ表のデータ行（区切り行の後）を返す。無ければ None。"""
    for i, line in enumerate(lines):
        head = cells(line)
        if head is None or head[: len(columns)] != columns:
            continue
        rows = []
        for row in lines[i + 2:]:
            c = cells(row)
            if c is None:
                break
            rows.append(c)
        return head, rows
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="調査レポートの形を確かめる")
    ap.add_argument("report")
    ap.add_argument("--heading", action="append", default=[])
    ap.add_argument("--table-columns")
    ap.add_argument("--min-rows", type=int, default=0)
    ap.add_argument("--evidence", action="store_true")
    ap.add_argument("--min-bytes", type=int, default=0)
    a = ap.parse_args(argv)
    try:
        sys.stderr.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    path = Path(a.report)
    if not path.is_file():
        print(f"error: レポートがありません: {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8-sig")
    lines = text.splitlines()
    problems = []
    if len(text.encode("utf-8")) < a.min_bytes:
        problems.append(f"小さすぎます（{len(text.encode('utf-8'))} < {a.min_bytes} バイト）")
    stripped = {line.strip() for line in lines}
    for h in a.heading:
        if h.strip() not in stripped:
            problems.append(f"見出しがありません: {h}")
    if a.table_columns:
        columns = [c.strip() for c in a.table_columns.split("|")]
        found = find_table(lines, columns)
        if found is None:
            problems.append(f"表がありません（見出しの列: {' | '.join(columns)}）")
        else:
            head, rows = found
            if len(rows) < a.min_rows:
                problems.append(f"表の行が足りません（{len(rows)} < {a.min_rows}）")
            if a.evidence:
                col = head.index("根拠") if "根拠" in head else len(head) - 1
                empty = [n for n, r in enumerate(rows, 1) if col >= len(r) or r[col] in ("", "-")]
                if empty:
                    problems.append(f"根拠が空の行があります（データ行の {empty[:10]} 行目）。確かめられないなら「未確認: 試したこと」と書く")
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
