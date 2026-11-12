#!/usr/bin/env python3
"""Lays out a call note as an A4 PDF that reads well on a phone.

Usage: pdf.py <note.md> <output.pdf> ["Title"] ["Subtitle"]
The note's YAML header is skipped, and so is the final "Transcript" section.
Needs a Chromium browser (Google Chrome, Chromium, Microsoft Edge or Brave), run headless;
CRT_CHROME can point to one.

The headless-Chrome trap: it writes the PDF and then does not exit. So we do not wait for
the process to end: we watch the file, and when it is there we close the browser.
"""
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crt_config  # noqa: E402

CFG = crt_config.load()
UI = CFG["CRT_UI_LANG"]

BROWSERS = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
]

CSS = """
@page { size: A4; margin: 18mm 17mm 20mm 17mm; }
* { box-sizing: border-box; }
body { font-family: "Iowan Old Style", "Palatino", Georgia, serif; font-size: 11pt;
       line-height: 1.5; color: #1a1a1a; margin: 0; }
.head { border-bottom: 1.5pt solid #1a1a1a; padding-bottom: 8pt; margin-bottom: 14pt; }
.head .kicker { font-size: 8.5pt; letter-spacing: 1.2pt; text-transform: uppercase; color: #777; }
.head h1 { font-size: 21pt; line-height: 1.15; margin: 3pt 0 2pt; }
.head .date { font-size: 10pt; color: #555; }
h2 { font-size: 13pt; margin: 18pt 0 6pt; padding-bottom: 2pt;
     border-bottom: 0.6pt solid #bbb; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 12pt 0 4pt; page-break-after: avoid; }
p { margin: 0 0 7pt; }
ul { margin: 0 0 9pt; padding-left: 16pt; }
ul ul { margin: 3pt 0 3pt; }
li { margin-bottom: 3pt; }
li.todo { list-style: none; margin-left: -14pt; }
.box { display: inline-block; width: 9pt; height: 9pt; border: 0.9pt solid #1a1a1a;
       margin-right: 5pt; vertical-align: -0.5pt; }
.notice { font-size: 9pt; color: #666; font-style: italic; margin-bottom: 12pt; }
code { font-family: Menlo, monospace; font-size: 9pt; background: #f2f2ef; padding: 0 2pt; }
.foot { margin-top: 22pt; padding-top: 6pt; border-top: 0.6pt solid #ccc;
        font-size: 8.5pt; color: #888; }
"""


def t(en, it):
    return it if UI == "it" else en


def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    s = re.sub(r"(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])", r"<em>\1</em>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    return s


def without_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            return text[end + 4:]
    return text


def item(line):
    """'- [ ] thing' → checkbox; '- thing' → plain item."""
    s = line.strip()[2:]
    m = re.match(r"\[( |x|X)\]\s*(.*)", s)
    if m:
        mark = "✓" if m.group(1).lower() == "x" else ""
        return '<li class="todo"><span class="box">%s</span>%s</li>' % (mark, inline(m.group(2)))
    return "<li>%s</li>" % inline(s)


def convert(text):
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        s = lines[i].strip()
        if not s:
            i += 1; continue
        # the closing "Transcript" section points to a file: the PDF does not need it
        if re.match(r"^##\s+(Transcript|Trascrizione)\s*$", s, re.I):
            break
        m = re.match(r"^(#{1,4}) (.*)", s)
        if m:
            level = max(2, len(m.group(1)))
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2)), level)); i += 1; continue
        if s.startswith("- ") or s.startswith("* "):
            out.append("<ul>")
            nested = False
            while i < len(lines) and re.match(r"^\s*[-*] ", lines[i]):
                indent = len(lines[i]) - len(lines[i].lstrip())
                if indent >= 2 and not nested:
                    out.append("<ul>"); nested = True
                elif indent < 2 and nested:
                    out.append("</ul>"); nested = False
                out.append(item(re.sub(r"^(\s*)\* ", r"\1- ", lines[i]))); i += 1
            if nested:
                out.append("</ul>")
            out.append("</ul>"); continue
        if s.startswith("_(") and s.endswith(")_"):
            out.append('<p class="notice">%s</p>' % inline(s[2:-2])); i += 1; continue
        if s == "---":
            out.append("<hr>"); i += 1; continue
        out.append("<p>%s</p>" % inline(s)); i += 1
    return "\n".join(out)


def find_browser():
    if CFG["CRT_CHROME"]:
        return CFG["CRT_CHROME"] if os.access(CFG["CRT_CHROME"], os.X_OK) else None
    for path in BROWSERS:
        for candidate in (path, os.path.expanduser("~" + path)):
            if os.access(candidate, os.X_OK):
                return candidate
    return None


def render(page_html, dst, browser):
    work = tempfile.mkdtemp(prefix="call-note-pdf-")
    source = os.path.join(work, "note.html")
    with open(source, "w", encoding="utf-8") as f:
        f.write(page_html)
    temp_pdf = os.path.join(work, "note.pdf")
    p = subprocess.Popen([browser, "--headless=new", "--disable-gpu", "--no-sandbox",
                          "--user-data-dir=" + os.path.join(work, "profile"),
                          "--no-pdf-header-footer", "--print-to-pdf=" + temp_pdf,
                          "file://" + source],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ready = False
    for _ in range(60):
        time.sleep(1)
        if os.path.exists(temp_pdf) and os.path.getsize(temp_pdf) > 1000:
            time.sleep(1.5); ready = True; break
    p.terminate()
    try:
        p.wait(timeout=5)
    except Exception:
        p.kill()
    if ready:
        os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
        shutil.copyfile(temp_pdf, dst)
    shutil.rmtree(work, ignore_errors=True)
    return ready


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: pdf.py <note.md> <output.pdf> [title] [subtitle]")
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else t("Call", "Riunione")
    subtitle = sys.argv[4] if len(sys.argv) > 4 else ""
    browser = find_browser()
    if not browser:
        sys.exit(t("No Chrome/Chromium/Edge/Brave found: skipping the PDF (set CRT_CHROME)",
                   "Nessun Chrome/Chromium/Edge/Brave trovato: niente PDF (imposta CRT_CHROME)"))
    with open(src, encoding="utf-8") as f:
        body = convert(without_frontmatter(f.read()))
    page = ("<html><head><meta charset='utf-8'><title>%s</title><style>%s</style></head><body>"
            "<div class='head'><div class='kicker'>%s</div>"
            "<h1>%s</h1><div class='date'>%s</div></div>%s"
            "<div class='foot'>%s</div>"
            "</body></html>") % (
        html.escape(title), CSS, t("Call · summary", "Riunione · sintesi"), html.escape(title),
        html.escape(subtitle), body,
        t("Automatic summary of a transcript made on this Mac. The full transcript is "
          "next to the note.",
          "Sintesi automatica di una trascrizione fatta su questo Mac. La trascrizione "
          "completa è accanto alla nota."))
    if not render(page, dst, browser):
        sys.exit(t("the browser did not produce the PDF", "il browser non ha prodotto il PDF"))
    print(dst)


if __name__ == "__main__":
    main()
