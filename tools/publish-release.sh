#!/bin/bash
#
# Выпуск маковой версии на GitHub — одной командой, из того, что уже лежит
# на сайте.
#
#   bash tools/publish-release.sh              # выпустить то, что стоит на scribla.io
#   bash tools/publish-release.sh --dry-run    # показать, что будет сделано
#   bash tools/publish-release.sh 1.0.2        # взять именно эту версию
#
# Правда о свежей версии живёт в одном месте — в download/mac.json на сайте:
# оттуда её берёт и сайт, и само установленное приложение, когда проверяет
# обновления. Поэтому здесь ничего не спрашивается и не вводится руками:
# скрипт читает mac.json, качает названный образ, СВЕРЯЕТ ОТПЕЧАТОК и только
# после этого заводит релиз. Сверка — не формальность: релиз GitHub раздаёт
# файл дальше от нашего имени, и выложить туда что-то, кроме заверенного
# Apple образа, значит подписаться под чужой сборкой.
#
# Что делает: тег mac-v<версия>, релиз с образом и заметками из mac.json,
# правит номер, вес и SHA-256 в обоих README и заводит запись в CHANGELOG,
# если её ещё нет.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="alvlsk12345/scribla-releases"
FEED="https://scribla.io/download/mac.json"

DRY=""
WANT=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY="да" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) WANT="$a" ;;
  esac
done

command -v gh >/dev/null || { echo "Нужен gh: brew install gh"; exit 1; }

echo "→ Читаю $FEED"
META="$(curl -fsS "$FEED")"
VERSION="$(printf '%s' "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
BUILD="$(printf '%s' "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])')"
SHA="$(printf '%s' "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
URL="$(printf '%s' "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"

if [ -n "$WANT" ] && [ "$WANT" != "$VERSION" ]; then
  echo "✗ На сайте стоит $VERSION, а просят $WANT."
  echo "  Сначала выкладка: bash Scripts/mac-release.sh --publish в репозитории кода."
  exit 1
fi

TAG="mac-v$VERSION"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "✓ Релиз $TAG уже есть — https://github.com/$REPO/releases/tag/$TAG"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DMG="$TMP/Scribla-$VERSION.dmg"

echo "→ Качаю $URL"
curl -fsS -o "$DMG" "$URL"

GOT="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA" ]; then
  echo "✗ Отпечаток не сошёлся — образ не тот, что обещает mac.json:"
  echo "  ждали $SHA"
  echo "  взяли $GOT"
  exit 1
fi
BYTES="$(stat -f%z "$DMG")"
SIZE="$(python3 -c "print(f'{$BYTES/1e6:.1f}'.replace('.', ','))") МБ"
SIZE_EN="$(python3 -c "print(f'{$BYTES/1e6:.1f}')") MB"
echo "  отпечаток сошёлся, $SIZE"

# ── Заметки к релизу ──────────────────────────────────────────────────
NOTES="$TMP/notes.md"
python3 - "$META" "$VERSION" "$BUILD" "$SHA" "$SIZE" > "$NOTES" <<'PY'
import json, sys
meta, version, build, sha, size = sys.argv[1:6]
notes = json.loads(meta).get("notes", {})
out = []
if notes.get("ru"):
    out += [notes["ru"], ""]
if notes.get("en"):
    out += ["<sub>English</sub>", "", notes["en"], ""]
out += [
    "---", "",
    f"**Версия** {version} (сборка {build}) · **Система** macOS 14 и новее, Apple Silicon и Intel · **Размер** {size}",
    "",
    "Образ подписан Developer ID и заверен у Apple — открывается двойным щелчком.",
    "",
    "```",
    f"SHA-256  {sha}",
    "```",
    "",
    "Тот же образ на сайте: https://scribla.io/download/Scribla.dmg",
]
print("\n".join(out))
PY

if [ -n "$DRY" ]; then
  echo "— сухой ход, дальше не иду. Заметки к релизу:"
  echo; cat "$NOTES"; echo
  exit 0
fi

echo "→ Завожу релиз $TAG"
gh release create "$TAG" "$DMG" \
  --repo "$REPO" \
  --title "Scribla для Mac $VERSION" \
  --notes-file "$NOTES" \
  --latest

# ── Подписи в README и запись в CHANGELOG ─────────────────────────────
#
# Номер, вес и отпечаток стоят на витрине в четырёх местах на два языка.
# Правились они руками ровно до первого раза, когда не поправили: на сайте
# это уже случалось, и лечили тем же — одним источником и машинной правкой.
python3 - "$VERSION" "$BUILD" "$SHA" "$SIZE" "$SIZE_EN" <<'PY'
import pathlib, re, sys
version, build, sha, size, size_en = sys.argv[1:6]

for name, size_str, ver_label, build_label in (
    ("README.md", size, "Версия", "сборка"),
    ("README.en.md", size_en, "Version", "build"),
):
    p = pathlib.Path(name)
    s = p.read_text()
    s = re.sub(r"Scribla-[0-9][0-9.]*\.dmg", f"Scribla-{version}.dmg", s)
    s = re.sub(rf"\| {ver_label} \| \*\*[^*]+\*\* \({build_label} \d+\) \|",
               f"| {ver_label} | **{version}** ({build_label} {build}) |", s)
    s = re.sub(r"\| (Размер|Size) \| [^|]+ \|", lambda m: f"| {m.group(1)} | {size_str} |", s)
    s = re.sub(r"`[0-9a-f]{64}`", f"`{sha}`", s)
    s = re.sub(r"\*\*Mac\*\* \| [0-9][0-9.]*", f"**Mac** | {version}", s)
    p.write_text(s)
    print(" ", name, "поправлен")

# Заготовка в CHANGELOG — только если этой версии там ещё нет.
for name, head, absent in (
    ("CHANGELOG.md", "## Mac", "Заметок к этой версии не писали."),
    ("CHANGELOG.en.md", "## Mac", "No notes were written for this version."),
):
    p = pathlib.Path(name)
    s = p.read_text()
    if f"### {version} " in s:
        continue
    lang = "ru" if name == "CHANGELOG.md" else "en"
    import json, urllib.request
    notes = json.loads(urllib.request.urlopen("https://scribla.io/download/mac.json").read())
    body = (notes.get("notes") or {}).get(lang) or absent
    date = "<!-- дата -->" if lang == "ru" else "<!-- date -->"
    tag = f"https://github.com/alvlsk12345/scribla-releases/releases/tag/mac-v{version}"
    label = "образ" if lang == "ru" else "image"
    entry = f"### {version} — {date} ([{label}]({tag}))\n\n{body}\n\n"
    s = s.replace(head + "\n\n", head + "\n\n" + entry, 1)
    p.write_text(s)
    print(" ", name, "— добавлена запись", version, "(проставьте дату)")
PY

echo
echo "Готово: https://github.com/$REPO/releases/tag/$TAG"
echo "Осталось: проставить дату в CHANGELOG и закоммитить правки витрины."
