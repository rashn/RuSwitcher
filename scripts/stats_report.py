#!/usr/bin/env python3
"""Ежедневный дайджест статистики RuSwitcher → Telegram.
Читает публичные счётчики GitHub (download_count релизов, звёзды), считает дельту
за сутки по истории stats/history.jsonl и шлёт отчёт в Telegram. Без телеметрии в
приложении — только агрегатные публичные числа GitHub. Зависимостей нет (urllib)."""
import json, os, urllib.request, urllib.parse, datetime

REPO = "rashn/RuSwitcher"
GH_TOKEN = os.environ.get("GITHUB_TOKEN", "")
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_CHAT = os.environ.get("TELEGRAM_CHAT_ID", "")
HIST = "stats/history.jsonl"
# Считаем и macOS (.dmg), и Windows (.exe) — с win-v0.9.0 у нас два трека релизов.
COUNTED_EXT = (".dmg", ".exe")


def gh(path):
    req = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={
            "Authorization": f"Bearer {GH_TOKEN}" if GH_TOKEN else "",
            "Accept": "application/vnd.github+json",
            "User-Agent": "ruswitcher-stats",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def brew_installs_30d():
    """Установки через официальный Homebrew за 30 дней (cask в каталоге с 2026-09-20).
    Открытая аналитика brew: считаются только пользователи с включённой brew analytics —
    недооценка, но тренд честный. Окно скользящее, так что дневная дельта может быть и
    отрицательной. При любой ошибке возвращаем None — строка просто не печатается."""
    try:
        req = urllib.request.Request(
            "https://formulae.brew.sh/api/cask/ruswitcher.json",
            headers={"User-Agent": "ruswitcher-stats"},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        val = data.get("analytics", {}).get("install", {}).get("30d", {}).get("ruswitcher")
        return int(str(val).replace(",", "")) if val is not None else None
    except Exception:
        return None


def main():
    repo = gh(f"repos/{REPO}")
    releases = gh(f"repos/{REPO}/releases?per_page=100")
    brew30 = brew_installs_30d()

    per, total = {}, 0
    for rel in releases:
        dl = sum(a["download_count"] for a in rel.get("assets", []) if a["name"].endswith(COUNTED_EXT))
        per[rel["tag_name"]] = dl
        total += dl
    stars = repo["stargazers_count"]

    # МСК-дата для метки
    today = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=3)).date().isoformat()
    snap = {"date": today, "total": total, "stars": stars, "brew30": brew30, "per": per}

    prev = None
    if os.path.exists(HIST):
        lines = [l for l in open(HIST, encoding="utf-8") if l.strip()]
        if lines:
            prev = json.loads(lines[-1])
    prev_per = prev.get("per", {}) if prev else {}

    # Идемпотентность по дню: расписание GitHub — best-effort (2026-08-27 крон молча
    # выпал), поэтому в workflow ДВА cron-слота. Если за сегодня уже отчитались —
    # второй прогон тихо выходит, не дублируя дайджест и снапшот.
    if prev and prev.get("date") == today:
        print(f"Already reported today ({today}) — skipping (backup cron slot).")
        return

    def d(cur, key):
        if prev is None or prev.get(key) is None:
            return ""
        diff = cur - prev[key]
        return f" (+{diff})" if diff > 0 else (f" ({diff})" if diff < 0 else "")

    def dtag(t):
        """Дельта по релизу; релиз, которого вчера не было, честно показываем как новый —
        иначе весь его прирост выпадает из «Изменений за сутки» (баг дайджеста 2026-08-11)."""
        if prev is None:
            return ""
        p = prev_per.get(t)
        if p is None:
            return f" (+{per[t]}, новый)" if per[t] else " (новый)"
        diff = per[t] - p
        return f" (+{diff})" if diff > 0 else (f" ({diff})" if diff < 0 else "")

    # Головные строки: стабильный macOS (не prerelease, не win-), актуальная бета
    # (prerelease НОВЕЕ стабильного, не win-), свежайший Windows-релиз.
    tags = [r["tag_name"] for r in releases]
    stable = next((r["tag_name"] for r in releases
                   if not r.get("prerelease") and not r["tag_name"].startswith("win-")), None)
    beta = next((r["tag_name"] for r in releases
                 if r.get("prerelease") and not r["tag_name"].startswith("win-")), None)
    if beta and stable and tags.index(beta) > tags.index(stable):
        beta = None  # бета старее стабильного = закрытый бета-цикл, не показываем
    win = next((t for t in tags if t.startswith("win-")), None)

    lines = [f"📊 RuSwitcher — {today}", ""]
    lines.append(f"Всего скачано: {total}{d(total, 'total')}")
    lines.append(f"⭐ Stars: {stars}{d(stars, 'stars')}")
    if brew30 is not None:
        lines.append(f"🍺 Homebrew за 30 дней: {brew30}{d(brew30, 'brew30')}")
    if stable:
        lines.append(f"Стабильный {stable}: {per[stable]}{dtag(stable)}")
    if beta:
        lines.append(f"Бета {beta}: {per[beta]}{dtag(beta)}")
    if win:
        lines.append(f"🪟 Windows {win}: {per[win]}{dtag(win)}")

    shown = {stable, beta, win} - {None}
    changed = [t for t in per
               if prev and t not in shown and (per[t] - prev_per.get(t, 0)) != 0]
    changed.sort(key=lambda t: per[t] - prev_per.get(t, 0), reverse=True)
    if changed:
        lines.append("")
        lines.append("Изменения за сутки:")
        for t in changed:
            lines.append(f"• {t}: {per[t]}{dtag(t)}")
    elif prev is not None and not shown:
        lines.append("")
        lines.append("За сутки без изменений по релизам.")
    report = "\n".join(lines)
    print(report)

    os.makedirs("stats", exist_ok=True)
    with open(HIST, "a", encoding="utf-8") as f:
        f.write(json.dumps(snap, ensure_ascii=False) + "\n")

    if TG_TOKEN and TG_CHAT:
        data = urllib.parse.urlencode({"chat_id": TG_CHAT, "text": report}).encode()
        req = urllib.request.Request(f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage", data=data)
        with urllib.request.urlopen(req, timeout=30) as r:
            print("telegram sent:", r.status)
    else:
        print("Telegram secrets not set — report printed only (add TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID).")


if __name__ == "__main__":
    main()
