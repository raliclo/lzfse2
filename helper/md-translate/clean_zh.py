#!/usr/bin/env python3
"""Remove English translations from OPTIMIZATION.md, keep Traditional Chinese only."""
import re, sys

CJK_IDEOGRAPH = re.compile(r'[一-鿿㐀-䶿豈-﫿]')
FULLWIDTH = re.compile(r'[（）、，。：！？【】《》「」『』〔〕]')

def has_cjk(s):
    return bool(CJK_IDEOGRAPH.search(s))

def has_chinese_context(s):
    """True if s has CJK ideographs OR fullwidth Chinese punctuation."""
    return bool(CJK_IDEOGRAPH.search(s)) or bool(FULLWIDTH.search(s))

def strip_heading_english(line):
    """
    Strip English translation suffix from heading lines.
    Checks each "/ Uppercase" segment from right to left;
    removes the rightmost one where the segment has no CJK
    and what precedes it has Chinese context.

    e.g. "## Lazy2 / Optimal 改善策略 / Strategy" → "## Lazy2 / Optimal 改善策略"
         "## 節名（2026）/ Title"               → "## 節名（2026）"
         "## trace / power / RSS 觀察"          → unchanged (RSS 觀察 has CJK)
    """
    # Find all "/ Uppercase" start positions
    slashes = list(re.finditer(r'\s*/\s+(?=[A-Z])', line))
    if not slashes:
        return line

    for i in reversed(range(len(slashes))):
        content_start = slashes[i].end()          # position of the uppercase letter
        slash_start = slashes[i].start()          # position of optional-ws before /
        # Segment = from uppercase letter to next slash (or end of line)
        segment_end = slashes[i+1].start() if i+1 < len(slashes) else len(line)
        segment = line[content_start:segment_end].strip()

        # Extract trailing （CJK） suffix (e.g. "Changes（R4 候選 #2 落地）")
        cjk_trail = ''
        m_trail = re.search(r'（[^）\n]*[一-鿿㐀-䶿][^）\n]*）\s*$', segment)
        if m_trail:
            cjk_trail = m_trail.group(0).strip()
            segment_core = segment[:m_trail.start()].strip()
        else:
            segment_core = segment

        if has_cjk(segment_core):
            continue   # main part contains CJK — genuinely Chinese, not a translation
        if not re.match(r'^[A-Z]', segment_core):
            continue   # not starting with uppercase — skip

        before = line[:slash_start].rstrip()
        if not has_chinese_context(before):
            continue   # nothing Chinese before this slash — don't strip

        # Append CJK suffix without extra space if it starts with fullwidth paren
        sep = '' if cjk_trail.startswith('（') else (' ' if cjk_trail else '')
        return before + sep + cjk_trail

    return line

def process(content):
    lines = content.split('\n')
    out = []
    in_code = False
    prev_was_cjk_comment = False

    for line in lines:
        # Track code fences
        if re.match(r'^\s*```', line):
            in_code = not in_code
            prev_was_cjk_comment = False
            out.append(line)
            continue

        if in_code:
            stripped = line.strip()
            is_comment = stripped.startswith('#')
            if is_comment:
                if has_cjk(line):
                    # Chinese comment: strip " / English" tail
                    line = re.sub(
                        r'\s*/\s+[A-Za-z][^\n]*$',
                        lambda m: '' if not has_cjk(m.group(0)) else m.group(0),
                        line
                    )
                    prev_was_cjk_comment = True
                else:
                    # Pure English comment: drop if immediately follows CJK comment
                    if prev_was_cjk_comment:
                        prev_was_cjk_comment = False
                        continue
                    prev_was_cjk_comment = False
            else:
                prev_was_cjk_comment = False
            out.append(line)
            continue

        prev_was_cjk_comment = False

        # ── 1. Heading lines: strip "/ English" suffix ────────────────────
        if re.match(r'^#+\s', line):
            line = strip_heading_english(line)

        # ── 2. English-only blockquote lines ──────────────────────────────
        if line.startswith('> '):
            body = line[2:]
            if body.strip() and not has_cjk(body):
                if out and out[-1].strip() == '>':
                    out.pop()
                continue

        # ── 3a. Inline **Chinese / English** bold labels ──────────────────
        # e.g. "**流程 / Procedure**：" → "**流程**："
        if '**' in line and '/' in line:
            line = re.sub(
                r'\*\*([^*]+?)\s*/\s+([A-Z][^*]+?)\*\*',
                lambda m: f'**{m.group(1).rstrip()}**'
                    if has_cjk(m.group(1)) and not has_cjk(m.group(2)) else m.group(0),
                line
            )

        # ── 3. Inline "/ English" in table column headers ─────────────────
        if '|' in line and '/' in line:
            line = re.sub(
                r'([一-鿿㐀-䶿\w\s（）]+)\s*/\s+([A-Z][^|/\n]*)',
                lambda m: m.group(1).rstrip() if not has_cjk(m.group(2)) else m.group(0),
                line
            )
            line = re.sub(r'  +\|', ' |', line)

        # ── 4. English-only bold-label lines ─────────────────────────────
        stripped = line.strip()
        if (stripped and not has_cjk(stripped)
                and re.match(r'^\*\*[A-Z][A-Za-z ]+\*\*[：:] ?.+', stripped)):
            continue

        # ── 5. Standalone English prose lines ─────────────────────────────
        if (stripped and not has_cjk(stripped)
                and not re.match(r'^[#|`\-*>0-9\[\]!_~@(（]', stripped)
                and stripped not in ('---', '...')
                and re.match(r'^[A-Z\*]', stripped)
                and len(stripped) > 12):
            continue

        out.append(line)

    # Post-process: collapse 3+ consecutive blank lines to 2
    final = []
    blanks = 0
    for ln in out:
        if ln.strip() == '':
            blanks += 1
            if blanks <= 2:
                final.append(ln)
        else:
            blanks = 0
            final.append(ln)

    return '\n'.join(final)

if __name__ == '__main__':
    path = sys.argv[1]
    with open(path, encoding='utf-8') as f:
        content = f.read()
    cleaned = process(content)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(cleaned)
    orig = content.count('\n')
    new = cleaned.count('\n')
    print(f"Done. Lines: {orig} → {new} (removed {orig - new})")
