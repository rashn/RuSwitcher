#!/usr/bin/env python3
"""Генератор языковых паков для конверсии на лету (InstantDetector).

Один пак = один ЯЗЫК, не пара: детектор берёт две языковые таблицы и сравнивает
«невозможно в своём / правдоподобно в чужом». Поэтому скачанные ru+en дают пару
ru↔en, а добавленный третий язык — сразу все пары с ним, без отдельной генерации.

Кладёт в dist/instant-tables/:
  <lang>.pack     — бинарь: маска допустимых триграмм + Bloom начал слов
  manifest.json   — индекс языков (версия, размер, sha256, имя файла)

Приложение данные с собой не возит: паки скачиваются по включению настройки,
проверяются по sha256 из манифеста и кэшируются в Application Support.

Корпус: hermitdave/FrequencyWords, OpenSubtitles-2018, top-50k слов на язык.
    curl -sL -o /tmp/ru_freq.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt
    curl -sL -o /tmp/en_freq.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
    python3 macos/tools/gen_instant_tables.py

Новый язык: добавить запись в LANGUAGES (код, алфавит, путь к частотному списку) и
перегенерировать — правки приложения не нужны, оно читает алфавит и параметры из пака.

Пороги подбирались по замерам на самом корпусе (учили на 80%, ложные считали на
отложенных 20% и на словаре Вебстера как «редкие слова»): комбинация двух моделей
даёт 0,14% ложных при отлове ~75% в среднем на 2,5-й букве.
"""
import collections, hashlib, json, os, struct

TRIGRAM_THRESHOLD = 1e-7   # доля от корпуса, ниже которой сочетание считаем невозможным
PREFIX_MAXLEN = 5          # длиннее не храним: там уже хватает статистики сочетаний
BLOOM_BITS_PER_ITEM = 10   # ≈0,8% ложноположительных при k=7
BLOOM_K = 7
PACK_MAGIC = b"RSIT"       # RuSwitcher Instant Tables
PACK_FORMAT = 1
TABLES_VERSION = 1         # растёт при смене корпуса/порогов — приложение перекачает пак

LANGUAGES = {
    "ru": {"alphabet": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя", "corpus": "/tmp/ru_freq.txt"},
    "en": {"alphabet": "abcdefghijklmnopqrstuvwxyz",        "corpus": "/tmp/en_freq.txt"},
}
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "instant-tables")


def load(path, alphabet):
    aset, out = set(alphabet), []
    for line in open(path, encoding="utf-8", errors="ignore"):
        p = line.split()
        if len(p) != 2:
            continue
        w, f = p[0].lower(), int(p[1])
        if w and all(c in aset for c in w):
            out.append((w, f))
    return out


def trigrams(word):
    s = "^" + word
    return [s[i:i + 3] for i in range(len(s) - 2)]


def build_trigrams(words):
    cnt, total = collections.Counter(), 0
    for w, f in words:
        total += f
        for t in trigrams(w):
            cnt[t] += f
    thr = total * TRIGRAM_THRESHOLD
    return {t for t, c in cnt.items() if c >= thr}


def encode_trigrams(allowed, alphabet):
    n = len(alphabet) + 1
    idx = lambda c: 0 if c == "^" else alphabet.index(c) + 1
    bits = bytearray((n * n * n + 7) // 8)
    for t in allowed:
        i = (idx(t[0]) * n + idx(t[1])) * n + idx(t[2])
        bits[i >> 3] |= 1 << (i & 7)
    return bytes(bits)


def fnv1a(data, seed):
    h = 0xcbf29ce484222325 ^ seed
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def build_prefixes(words):
    s = set()
    for w, _ in words:
        for n in range(1, min(len(w), PREFIX_MAXLEN) + 1):
            s.add(w[:n])
    return s


def encode_bloom(items):
    m = max(8, len(items) * BLOOM_BITS_PER_ITEM)
    bits = bytearray((m + 7) // 8)
    for s in items:
        data = s.encode("utf-8")
        h1, h2 = fnv1a(data, 0), fnv1a(data, 0x9E3779B97F4A7C15)
        for i in range(BLOOM_K):
            # маска обязательна: в Swift эта арифметика wrapping (&+, &*), а у Python числа
            # неограниченные — без обрезки до 64 бит генератор и приложение расходятся в битах
            bit = ((h1 + i * h2) & 0xFFFFFFFFFFFFFFFF) % m
            bits[bit >> 3] |= 1 << (bit & 7)
    return bytes(bits), m


def build_pack(lang, alphabet, words):
    """Бинарь пака. Всё, что нужно для чтения (алфавит, параметры Bloom), лежит внутри —
    приложение не знает про языки заранее и не требует правок под новый пак."""
    ngram = encode_trigrams(build_trigrams(words), alphabet)
    bloom, m = encode_bloom(build_prefixes(words))
    lang_b, alpha_b = lang.encode("utf-8"), alphabet.encode("utf-8")
    out = bytearray()
    out += PACK_MAGIC
    out += struct.pack("<BB", PACK_FORMAT, TABLES_VERSION)
    out += struct.pack("<B", len(lang_b)) + lang_b
    out += struct.pack("<H", len(alpha_b)) + alpha_b
    out += struct.pack("<I", len(ngram)) + ngram
    out += struct.pack("<IBB", m, BLOOM_K, PREFIX_MAXLEN)
    out += struct.pack("<I", len(bloom)) + bloom
    return bytes(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = {"formatVersion": PACK_FORMAT, "languages": {}}
    for lang, cfg in LANGUAGES.items():
        words = load(cfg["corpus"], cfg["alphabet"])
        pack = build_pack(lang, cfg["alphabet"], words)
        name = f"{lang}.pack"
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(pack)
        manifest["languages"][lang] = {
            "file": name,
            "size": len(pack),
            "sha256": hashlib.sha256(pack).hexdigest(),
            "version": TABLES_VERSION,
        }
        print(f"{lang}: {len(pack)} Б из {len(words)} слов")
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"манифест: {os.path.abspath(os.path.join(OUT, 'manifest.json'))}")


if __name__ == "__main__":
    main()
