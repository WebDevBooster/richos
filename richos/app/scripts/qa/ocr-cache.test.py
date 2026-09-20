#!/usr/bin/env python3
"""Exercise the reader boundary with a fallible executable, not mocked cache results."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'lib'))
import qaocr


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='ocr-tests-')
        self.root=Path(self.tmp.name)
        self.old=dict(os.environ)
        self.reader=self.root/'reader'
        self.reader.write_text('''#!/usr/bin/env python3
import os,sys,pathlib
p=pathlib.Path(os.environ['OCR_TEST_ROOT'])
if '--version' in sys.argv: print('test-reader 1'); sys.exit(0)
if '--list-langs' in sys.argv: print('test-reader no data directory'); sys.exit(0)
with (p/'calls').open('a') as f: f.write('read\\n')
if (p/'fail').exists(): sys.exit(7)
print((p/'answer').read_text(),end='')
''')
        self.reader.chmod(0o755)
        os.environ.update(RICHOS_QA_TESSERACT=str(self.reader),RICHOS_QA_OCR_CACHE=str(self.root/'cache'),OCR_TEST_ROOT=str(self.root))
        self.image=self.root/'0001.png';self.image.write_bytes(b'frame one')
        (self.root/'answer').write_text('alpha beta')
        qaocr.reader_identity.cache_clear()
    def tearDown(self):
        os.environ.clear();os.environ.update(self.old);self.tmp.cleanup()
    def calls(self):return len((self.root/'calls').read_text().splitlines())
    def test_hits_and_byte_invalidation(self):
        self.assertEqual(qaocr.text(self.image),'alpha beta')
        qaocr.text(self.image);self.assertEqual(self.calls(),1)
        self.image.write_bytes(b'redacted');qaocr.text(self.image);self.assertEqual(self.calls(),2)
        os.environ['RICHOS_QA_OCR_ARGS']='["--psm", "6"]'
        qaocr.text(self.image);self.assertEqual(self.calls(),3)
    def test_error_is_not_empty_success(self):
        (self.root/'fail').touch()
        with self.assertRaises(qaocr.OcrUnavailable):qaocr.text(self.image)
        self.assertFalse((self.root/'cache').exists())
        (self.root/'fail').unlink();(self.root/'answer').write_text('')
        self.assertEqual(qaocr.text(self.image),'')
        self.assertEqual(qaocr.text(self.image),'');self.assertEqual(self.calls(),2)
    def test_control_still_executes_reader(self):
        qaocr.text(self.image);(self.root/'fail').touch()
        with self.assertRaises(qaocr.OcrUnavailable):qaocr.text(self.image,fresh=True)
        self.assertEqual(self.calls(),2)
    def test_multiple_patterns_join_clock(self):
        (self.root/'meta.tsv').write_text('t_action_before\t10000\nt_action_after\t10100\nframe\t1\t10500\n')
        command=[sys.executable,str(HERE/'ocr-find.py'),'alpha',str(self.image),'--pattern','beta','--first','--timeline','--json']
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        records=[json.loads(x) for x in result.stdout.splitlines()]
        self.assertEqual(len(records),2);self.assertEqual(records[0]['offset_ms'],500)
        self.assertEqual(self.calls(),1)
        subprocess.run(command,capture_output=True);self.assertEqual(self.calls(),1)
    def test_configuration_contents_invalidate_cache(self):
        data=self.root/'data';data.mkdir();(data/'eng.traineddata').write_text('v1')
        os.environ['TESSDATA_PREFIX']=str(data)
        qaocr.text(self.image);qaocr.text(self.image);self.assertEqual(self.calls(),1)
        (data/'eng.traineddata').write_text('version2')
        qaocr.text(self.image);self.assertEqual(self.calls(),2)
    def test_flat_excludes_second_region(self):
        nested=self.root/'b';nested.mkdir();(nested/'0001.png').write_bytes(b'phone')
        result=subprocess.run([sys.executable,str(HERE/'ocr-find.py'),'missing',str(self.root),'--flat','--quiet'],capture_output=True,text=True)
        self.assertEqual(result.returncode,1,result.stderr);self.assertEqual(self.calls(),1)
    def test_corrupt_cache_is_rebuilt(self):
        qaocr.text(self.image)
        next((self.root/'cache').glob('*.json')).write_text('{')
        self.assertEqual(qaocr.text(self.image),'alpha beta');self.assertEqual(self.calls(),2)


if __name__=='__main__':unittest.main()
