"""Select Verilog compilation units reachable from a concrete testbench.

Vendor encrypted units are supplied explicitly by the caller. This helper
only recognizes instantiations of modules declared in the ordinary RTL files.
"""
import re


def reachable_files(testbench_text, candidates):
    units={}
    text_by_file={}
    for path in candidates:
        text=re.sub(r'/\*.*?\*/|//[^\n]*','',path.read_text(encoding='utf-8',errors='replace'),flags=re.S)
        text_by_file[path]=text
        for name in re.findall(r'\bmodule\s+(\w+)',text):
            units[name]=path
    pending=[testbench_text]
    selected=set()
    while pending:
        text=pending.pop()
        for name,path in units.items():
            if path not in selected and re.search(r'\b'+re.escape(name)+r'\s*(?:#\s*\([^;]*?\)\s*)?\w+\s*\(',text,re.S):
                selected.add(path)
                pending.append(text_by_file[path])
    return sorted(selected)
