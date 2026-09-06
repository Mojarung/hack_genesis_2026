from pypdf import PdfReader
import sys
for n in sys.argv[1:]:
    r = PdfReader(n); p = r.pages[0]; print(n.split('\\')[-1], len(r.pages), 'pages', float(p.mediabox.width), 'x', float(p.mediabox.height), 'pt')
