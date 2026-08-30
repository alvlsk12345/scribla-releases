#!/bin/bash
#
# Выпуск маковой версии на GitHub — одной командой, из того, что уже лежит
# на сайте.
#
#   bash tools/publish-release.sh              # выпустить то, что стоит на scribla.io
#   bash tools/publish-release.sh --dry-run    # показать, что будет сделано
#   bash tools/publish-release.sh 1.0.2        # взять именно эту версию
#   bash tools/publish-release.sh --no-push    # не коммитить правки витрины
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
# правит номер, вес и SHA-256 в обоих README, заводит запись в CHANGELOG
# на обоих языках — и коммитит эти четыре файла с пушем в main.
#
# Запускать после `Scripts/mac-release.sh --publish` в репозитории кода —
# или не запускать вовсе: тот скрипт зовёт этот сам, когда выкладка на сайт
# прошла. Повторный запуск ничего не портит: увидев готовый релиз, выходит.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="alvlsk12345/scribla-releases"
FEED="https://scribla.io/download/mac.json"

DRY=""
NOPUSH=""
WANT=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY="да" ;;
    --no-push) NOPUSH="да" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
python3 - "$VERSION" "$BUILD" "$SHA" "$SIZE" "$SIZE_EN" "$META" <<'PY'
import datetime, json, pathlib, re, sys
version, build, sha, size, size_en, meta = sys.argv[1:7]

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

# Запись в CHANGELOG — только если этой версии там ещё нет. Дата ставится
# сегодняшняя: выпуск и есть сегодня. Раньше здесь стоял плейсхолдер, который
# полагалось дописать руками, — то есть однажды не дописать.
MONTHS = ("января февраля марта апреля мая июня июля августа сентября "
          "октября ноября декабря").split()
today = datetime.date.today()
notes = (json.loads(meta).get("notes") or {})
tag = f"https://github.com/alvlsk12345/scribla-releases/releases/tag/mac-v{version}"

for name, lang, label, absent, date in (
    ("CHANGELOG.md", "ru", "образ", "Заметок к этой версии не писали.",
     f"{today.day} {MONTHS[today.month - 1]} {today.year}"),
    ("CHANGELOG.en.md", "en", "image", "No notes were written for this version.",
     today.strftime("%-d %B %Y")),
):
    p = pathlib.Path(name)
    s = p.read_text()
    if f"### {version} " in s:
        continue
    body = notes.get(lang) or notes.get("en") or absent
    entry = f"### {version} — {date} ([{label}]({tag}))\n\n{body}\n\n"
    s = s.replace("## Mac\n\n", "## Mac\n\n" + entry, 1)
    p.write_text(s)
    print(" ", name, "— добавлена запись", version)
PY

# ── Витрина следом за релизом ─────────────────────────────────────────
#
# Коммитим только свои четыре файла: в дереве могут лежать чужие правки,
# и утащить их в коммит «выпуск такой-то» — верный способ потерять их след.
if [ -z "$NOPUSH" ]; then
  if [ -n "$(git status --porcelain README.md README.en.md CHANGELOG.md CHANGELOG.en.md)" ]; then
    git add README.md README.en.md CHANGELOG.md CHANGELOG.en.md
    git commit -q -m "Витрина: Scribla для Mac $VERSION"
    git push -q origin HEAD && echo "  витрина обновлена и запушена"
  fi
else
  echo "  правки витрины оставлены незакоммиченными (--no-push)"
fi

echo
echo "Готово: https://github.com/$REPO/releases/tag/$TAG"
