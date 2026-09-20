"""The custom rules inspect simple shell statements, not heredoc contents.

Heredocs can be data or programs for another interpreter. Their meaning is
outside these structural rules. ShellCheck remains responsible for shell parsing.
"""
import re


def statements(text):
    pending = []
    result = []
    for line in text.splitlines():
        if pending:
            delimiter, tabs = pending[0]
            if (line.lstrip('\t') if tabs else line) == delimiter:
                pending.pop(0)
            result.append('')
            continue
        if line.lstrip().startswith('#'):
            result.append('')
            continue
        for match in re.finditer(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2", line):
            pending.append((match[3], bool(match[1])))
        result.append(line)
    return '\n'.join(result)
