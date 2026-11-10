#!/usr/bin/env python3
"""Reference for spec/gazette.md: templates and the composer of the morning issue.
   python3 spec/tools/check-gazette.py           check spec/gazette-cases.json
   python3 spec/tools/check-gazette.py --write   rewrite the expected issues (read them before committing)
   python3 spec/tools/check-gazette.py --show ID print one composed issue as text"""
import datetime, json, pathlib, re, sys

SPEC = pathlib.Path(__file__).resolve().parent.parent
CASES = SPEC / "gazette-cases.json"
PLACEHOLDER = re.compile(r"\{([a-z_]+)(?:~([mfn]))?(\^)?(?:\|([^{}|]*)\|([^{}|]*)\|([^{}|]*))?\}")
TAIL = re.compile(r"[a-z0-9_.-]{1,32}")
ITEMS = 5
KINDS = {"link", "desk", "archive", "issue", "net"}
BIG = 100 * 1024 * 1024
MB = 1024 * 1024


class Templates:
    def __init__(self, text, platform="mac"):
        self.t, self.platform, self.used = {}, platform, set()
        for line in text.splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            key, sep, value = line.partition(" = ")
            if not sep or key in self.t:
                raise ValueError(f"bad template line: {line!r}")
            self.t[key] = value

    def raw(self, key):
        for k in (f"{key}.{self.platform}", key):
            if k in self.t:
                self.used.add(k)
                return self.t[k]
        raise KeyError(key)

    def list(self, key):
        return self.raw(key).split("|")

    def render(self, text, values):
        def sub(m):
            name, gender, cap, one, few, many = m.groups()
            v = values[name]
            if one is not None:
                out = (one, few, many)[plural(v)]
            elif gender:
                words = self.list("number." + gender)
                out = words[v - 1] if 1 <= v <= len(words) else str(v)
            else:
                out = str(v)
            return out[:1].upper() + out[1:] if cap else out
        return PLACEHOLDER.sub(sub, text)

    def __call__(self, key, **values):
        return self.render(self.raw(key), values)


def plural(n):
    n = abs(n)
    if n % 10 == 1 and n % 100 != 11:
        return 0
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return 1
    return 2


def size(b):
    """Bytes as a person reads them: whole Б, КБ, МБ (half up), ГБ with one decimal."""
    if b < 1024:
        return f"{b} Б"
    if b < 1024 ** 2:
        return f"{(b * 2 + 1024) // 2048} КБ"
    if b < 1024 ** 3:
        return f"{(b * 2 + MB) // (2 * MB)} МБ"
    tenths = (b * 20 + 1024 ** 3) // (2 * 1024 ** 3)
    return f"{tenths // 10},{tenths % 10} ГБ"


def instant(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")


def compose(inp, text):
    T = Templates(text, inp["platform"])
    tz = datetime.timedelta(minutes=inp["tz"])
    frm, to = instant(inp["from"]), instant(inp["to"])
    today = (to + tz).date()
    months = T.list("month")

    def local(e):
        return instant(e["at"]) + tz

    def clock(e):
        return local(e).strftime("%H:%M")

    def when(e):
        d = local(e).date()
        if d == today:
            return T("when.today", time=clock(e))
        if d == today - datetime.timedelta(days=1):
            return T("when.yesterday", time=clock(e))
        return T("when.date", day=d.day, month=months[d.month - 1], time=clock(e))

    def capped(items):
        return items[:ITEMS], T("more", n=len(items) - ITEMS) if len(items) > ITEMS else ""

    def story(rubric, title, body, items=()):
        shown, more = capped(list(items))
        return {"rubric": T("rubric." + rubric), "title": title, "body": body, "items": shown, "more": more}

    events = sorted((e for e in inp["events"] if e.get("kind") in KINDS), key=lambda e: instant(e["at"]))
    period = [e for e in events if frm < instant(e["at"]) <= to]
    week = [e for e in events if to - datetime.timedelta(days=7) < instant(e["at"]) <= to]
    state = inp["state"]
    desk = state.get("desk")

    issues = [e for e in period if e["kind"] == "issue"]
    tails = [e for e in period if e["kind"] == "link" and e["class"] == "gives_away"]
    tracks = [e for e in period if e["kind"] == "link" and e["class"] == "tracks"]
    moved = [e for e in period if e["kind"] == "desk" and e["what"] == "moved" and not e.get("copy")]
    copies = [e for e in period if e["kind"] == "desk" and e["what"] == "moved" and e.get("copy")]
    returned = [e for e in period if e["kind"] == "desk" and e["what"] == "returned"]
    added = [e for e in period if e["kind"] == "archive" and e["what"] == "added"]

    stories = []
    if len(issues) == 1:
        e = issues[0]
        body = [T("reprint.one.body", when=when(e), title=e["title"]), T("reprint.where")]
        if desk is not None:
            body.append(T("reprint.spoil"))
        stories.append(story("reprint", T("reprint.one.title", title=e["title"]), body))
    elif issues:
        stories.append(story("reprint", T("reprint.many.title", n=len(issues)),
                             [T("reprint.many.body"), T("reprint.where")],
                             [[local(e).strftime("%d.%m %H:%M"), e["title"]] for e in issues]))

    if tails:
        groups = {}
        for e in tails:
            names = [t if TAIL.fullmatch(t) else "" for t in e.get("tails", [])] or [""]
            for name in dict.fromkeys(names):
                key = (e.get("service") or "other", name)
                groups[key] = groups.get(key, 0) + 1
        items = []
        for (service, name), n in groups.items():
            if "service." + service not in T.t:
                service = "other"
            what = T("editing.item", tail=name) if name else T("editing.item.unnamed")
            if n > 1:
                what += T("editing.item.times", n=n)
            items.append([T("service." + service), what])
        body = [T("editing.body", n=len(tails))]
        if tracks:
            body.append(T("editing.also", n=len(tracks)))
        stories.append(story("editing", T("editing.title", n=len(tails)), body, items))

    if moved:
        body = [T("desk.moved.body", n=len(moved))]
        if copies:
            body.append(T("desk.copies", n=len(copies)))
        if returned:
            body.append(T("desk.returned", n=len(returned)))
        stories.append(story("desk", T("desk.moved.title", n=len(moved)), body, [[e["name"]] for e in moved]))
    elif copies:
        stories.append(story("desk", T("desk.copies.title", n=len(copies)), [T("desk.copies.body")]))
    elif desk and desk.get("next"):
        nx = desk["next"]
        left = nx["left"]
        within = T("desk.in.now") if left <= 0 else T("desk.in.tomorrow") if left == 1 else T("desk.in.days", n=left)
        body = T("desk.state", files=desk["files"], week=desk["week"]) if desk["week"] else T("desk.state.none", files=desk["files"])
        stories.append(story("desk", T(f"desk.next.{nx['to']}.title", name=nx["name"], **{"in": within}), [body]))
    elif desk and desk["week"]:
        stories.append(story("desk", T("desk.week.title", n=desk["week"]), [T("desk.week.body", files=desk["files"])]))

    if len(added) == 1:
        e = added[0]
        stories.append(story("archive", T("archive.one.title", title=e["title"]),
                             [T("archive.by.desk" if e.get("by") == "desk" else "archive.by.hand"), T("archive.sealed")]))
    elif added:
        stories.append(story("archive", T("archive.many.title", n=len(added)), [T("archive.many.body")],
                             [[e["title"]] for e in added]))

    if tracks and not tails:
        stories.append(story("editing", T("editing.tracks.title", n=len(tracks)), [T("editing.tracks.body")]))

    if not stories:
        first = inp["number"] == 1
        stories.append(story("empty", T("first.title" if first else "empty.title"), [T("first.body" if first else "empty.body")]))

    nets = [e for e in period if e["kind"] == "net"]
    period = [e for e in period if e["kind"] != "net"]

    def target(e):
        if e.get("vpn"):
            return T("sources.to.vpn")
        if not e.get("to"):
            return T("sources.to.unknown")
        return T("sources.to.cloud", company=e["to"]) if e.get("cloud") else e["to"]

    big = sorted((e for e in nets if e["sent"] >= BIG), key=lambda e: -e["sent"])
    new = list({(e["app"], target(e)): e for e in reversed([e for e in nets if e.get("first")])}.values())[::-1]
    sent = {}
    for e in nets:
        sent[e["app"]] = sent.get(e["app"], 0) + e["sent"]
    rows = [[clock(e), T("sources.item.big", app=e["app"], to=target(e), size=size(e["sent"]))] for e in big[:3]]
    rows += [[T("sources.new.label"), T("sources.item.new", app=e["app"], to=target(e))] for e in new[:3]]
    if sent:
        top = max(sent, key=sent.get)
        if sent[top] >= MB:
            rows.append([T("sources.top.label"), T("sources.item.top", app=top, size=size(sent[top]))])
    if big:
        night = (instant(big[0]["at"]) + tz).hour < 6
        head = T("sources.big.night.title" if night else "sources.big.title", app=big[0]["app"], size=size(big[0]["sent"]))
    elif new:
        head = T("sources.new.title", app=new[0]["app"], to=target(new[0]))
    elif nets:
        head = T("sources.count.title", n=len(sent))
    else:
        head = ""
    shown, more = capped(rows)
    sources = {"rubric": T("sources.rubric"), "title": head, "items": shown, "more": more,
               "note": "" if nets else T("sources.none" if state.get("sources") else "sources.off")}

    if issues or tails:
        reasons = [T("weather.busy")]
        if issues:
            reasons.append(T("weather.issues", n=len(issues)))
        if tails:
            reasons.append(T("weather.tails", n=len(tails)))
        weather = ", ".join(reasons)
    else:
        weather = T("weather.calm" if period else "weather.quiet")

    week_line = T("week", issues=sum(e["kind"] == "issue" for e in week),
                  links=sum(e["kind"] == "link" for e in week),
                  desk=sum(e["kind"] == "desk" and e["what"] == "moved" for e in week))

    docs = state.get("documents", [])
    dated = sorted((d for d in docs if d.get("expires")), key=lambda d: d["expires"])
    if not state.get("archive"):
        document = {"rubric": T("doc.rubric.archive"), "title": T("doc.none.title"), "note": T("doc.none.note")}
    elif not docs:
        document = {"rubric": T("doc.rubric.archive"), "title": T("doc.empty.title"), "note": T("doc.empty.note")}
    elif dated:
        d = dated[0]
        day = datetime.date.fromisoformat(d["expires"])
        left = (day - today).days
        v = dict(title=d["title"], day=day.day, month=months[day.month - 1], year=day.year)
        suffix = "" if day.year == today.year else ".year"
        if left > 0:
            title, note = T("doc.expires.title" + suffix, **v), T("doc.expires.note", n=left)
        elif left == 0:
            title, note = T("doc.today.title", **v), ""
        else:
            title, note = T("doc.expired.title" + suffix, **v), T("doc.expired.note", n=-left)
        document = {"rubric": T("doc.rubric.expires"), "title": title, "note": note}
    else:
        d = min(docs, key=lambda d: d["added"])
        age = (today - datetime.date.fromisoformat(d["added"])).days
        document = {"rubric": T("doc.rubric.oldest"), "title": d["title"],
                    "note": T("doc.oldest.note", n=age) if age > 0 else T("doc.oldest.new")}

    week_issues = [e for e in week if e["kind"] == "issue"][::-1]
    shown, more = capped([[local(e).strftime("%d.%m"), e["title"]] for e in week_issues])
    issued = {"rubric": T("issued.rubric"), "items": shown, "more": more, "note": "" if shown else T("issued.none")}

    issue = {
        "format": 1, "number": inp["number"], "date": today.isoformat(), "from": inp["from"], "to": inp["to"],
        "dateline": T("dateline", weekday=T.list("weekday")[today.weekday()], day=today.day,
                      month=months[today.month - 1], year=today.year),
        "weather": weather, "week": week_line, "stories": stories, "sources": sources, "document": document, "issued": issued,
        "colophon": [T("colophon.left"), T("colophon.next", hour=inp["hour"])],
    }
    return issue, T.used


def texts(issue):
    yield from (issue["dateline"], issue["weather"], issue["week"], *issue["colophon"])
    for s in issue["stories"]:
        yield from (s["rubric"], s["title"], *s["body"], s["more"])
        for row in s["items"]:
            yield from row
    yield from (issue["sources"]["rubric"], issue["sources"]["title"], issue["sources"]["more"], issue["sources"]["note"])
    for row in issue["sources"]["items"]:
        yield from row
    yield from issue["document"].values()
    yield from (issue["issued"]["rubric"], issue["issued"]["more"], issue["issued"]["note"])


def show(issue):
    print(f"{issue['dateline']}    Редакция    № {issue['number']}")
    print(f"Погода приватности: {issue['weather']}    {issue['week']}\n")
    for s in issue["stories"]:
        print(f"[{s['rubric']}] {s['title']}")
        for p in s["body"]:
            print("   " + p)
        for row in s["items"]:
            print("   · " + "  ".join(row))
        if s["more"]:
            print("   " + s["more"])
        print()
    x = issue["sources"]
    print(f"[{x['rubric']}] {x['title']} {x['note']}")
    for row in x["items"]:
        print("   · " + "  ".join(row))
    if x["more"]:
        print("   " + x["more"])
    d = issue["document"]
    print(f"[{d['rubric']}] {d['title']}  {d['note']}")
    i = issue["issued"]
    print(f"[{i['rubric']}] " + "; ".join(" ".join(r) for r in i["items"]) + i["more"] + i["note"])
    print("  |  ".join(issue["colophon"]))


def main():
    text = (SPEC / "gazette/ru/templates.txt").read_text(encoding="utf-8")
    cases = json.loads(CASES.read_text(encoding="utf-8"))
    write = "--write" in sys.argv
    failed, used, ids = 0, set(), set()

    def fail(what):
        nonlocal failed
        failed += 1
        print("FAIL " + what)

    T = Templates(text)
    for b, want in cases["sizes"]:
        if size(b) != want:
            fail(f"size {b}: got {size(b)!r}, want {want!r}")
    for p in cases["phrases"]:
        got = T.render(p["template"], p["values"])
        if got != p["expect"]:
            fail(f"phrase {p['id']}: got {got!r}, want {p['expect']!r}")
    for c in cases["issues"]:
        if c["id"] in ids:
            fail(f"{c['id']}: duplicate id")
        ids.add(c["id"])
        issue, u = compose(c["input"], text)
        used |= u
        if "--show" in sys.argv and sys.argv[-1] in (c["id"], "all"):
            print(f"--- {c['id']}: {c['note']}")
            show(issue)
        for t in texts(issue):
            if "—" in t or "!" in t or "{" in t or "}" in t or t != t.strip() or "  " in t:
                fail(f"{c['id']}: text is not dry or not rendered: {t!r}")
        if write:
            c["expect"] = issue
        elif issue != c.get("expect"):
            fail(f"{c['id']}: issue differs from expect")
            for k in issue:
                if issue[k] != (c.get("expect") or {}).get(k):
                    print(f"   {k}: got {json.dumps(issue[k], ensure_ascii=False)}")
    for key in sorted(set(T.t) - used - {"number.m", "number.f", "number.n"}):
        fail(f"coverage: no case uses template {key}")
    if write:
        CASES.write_text(json.dumps(cases, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"wrote {CASES.name}: read the expected issues before committing")
    print(f"gazette: {len(cases['phrases'])} phrases, {len(cases['issues'])} issues: "
          + ("all passed" if failed == 0 else f"{failed} problems"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
