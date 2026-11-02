"""Read supplied EPUBs for CSS-engine research; never execute book content.

Only structural metadata/style declarations are reported, not novel text.
The original archives remain untouched. Run with the existing QA Python runtime.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import posixpath
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit
import zipfile

from lxml import etree
import tinycss2


def audit(path):
    result = {'file': path.name, 'bytes': path.stat().st_size,
              'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    props, ats, tags = Counter(), Counter(), Counter()
    samples, css_files, docs, fonts = defaultdict(list), [], [], []
    errors = []
    parser = etree.XMLParser(resolve_entities=False, load_dtd=False,
                             no_network=True, recover=True)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        assert len(entries) <= 5000
        assert sum(info.file_size for info in entries) <= 256 * 1024 * 1024
        names = set(archive.namelist())
        result['zipEntries'] = len(entries)
        result['encryptedResources'] = 'META-INF/encryption.xml' in names

        def read(name):
            assert archive.getinfo(name).file_size <= 16 * 1024 * 1024
            return archive.read(name)

        def xml(name):
            return etree.fromstring(read(name), parser)

        def local(base, href):
            u = urlsplit(href)
            if u.scheme or u.netloc:
                return None
            target = posixpath.normpath(posixpath.join(posixpath.dirname(base), unquote(u.path)))
            return target if not target.startswith(('../', '/')) else None

        def declarations(nodes, source, selector):
            for item in nodes:
                if item.type != 'declaration':
                    continue
                name = item.lower_name
                value = tinycss2.serialize(item.value).strip()
                props[name] += 1
                sample = {'source': source, 'selector': selector[:180],
                          'value': value[:280], 'important': item.important}
                if len(samples[name]) < 5:
                    samples[name].append(sample)

        def rules(nodes, source):
            for item in nodes:
                if item.type == 'qualified-rule':
                    selector = tinycss2.serialize(item.prelude).strip()
                    declarations(tinycss2.parse_declaration_list(item.content,
                                 skip_whitespace=True, skip_comments=True), source, selector)
                elif item.type == 'at-rule':
                    ats[item.lower_at_keyword] += 1
                    if item.content is None:
                        continue
                    if item.lower_at_keyword in ('media', 'supports', 'layer', 'container'):
                        rules(tinycss2.parse_rule_list(item.content,
                              skip_whitespace=True, skip_comments=True), source)
                    else:
                        declarations(tinycss2.parse_declaration_list(item.content,
                                     skip_whitespace=True, skip_comments=True), source,
                                     '@' + item.lower_at_keyword)
                elif item.type == 'error':
                    errors.append({'source':source, 'message': item.message})

        container = xml('META-INF/container.xml')
        opf_path = unquote(container.find('.//{*}rootfile').get('full-path'))
        opf = xml(opf_path)
        metadata = opf.find('{*}metadata')
        result.update({'opf':opf_path, 'epubVersion':opf.get('version'),
                       'languages':[x.text for x in metadata.findall('{*}language')],
                       'renditionMetadata':[{k:v for k,v in x.attrib.items()} | {'value':x.text}
                                            for x in metadata.findall('{*}meta')
                                            if 'rendition:' in (x.get('property') or '')]})
        manifest = {x.get('id'): {'path':local(opf_path, x.get('href', '')),
                    'type':x.get('media-type'), 'properties':x.get('properties', '')}
                    for x in opf.findall('{*}manifest/{*}item')}
        spine = [manifest[x.get('idref')]['path'] for x in opf.findall('{*}spine/{*}itemref')]
        result['spine'] = spine
        result['spineItemProperties'] = [dict(x.attrib) for x in opf.findall('{*}spine/{*}itemref')]
        result['spineDirection'] = opf.find('{*}spine').get('page-progression-direction', 'default')
        result['manifestMissingFiles'] = [v['path'] for v in manifest.values()
                                          if v['path'] not in names]
        for name in sorted(names):
            if name.lower().endswith('.css'):
                source = read(name).decode('utf-8-sig', errors='replace')
                nodes = tinycss2.parse_stylesheet(source, skip_whitespace=True, skip_comments=True)
                rules(nodes, name)
                css_files.append({'path':name, 'bytes':len(source.encode()),
                                  'sha256':hashlib.sha256(read(name)).hexdigest()})
            elif re.search(r'\.(ttf|otf|woff2?)$', name, re.I):
                fonts.append({'path':name, 'bytes':archive.getinfo(name).file_size})
            elif re.search(r'\.(xhtml|html|htm)$', name, re.I):
                document = xml(name)
                if document is None:
                    errors.append({'source':name, 'message':'No document root'})
                    continue
                counts, inline = Counter(), 0
                for el in document.iter():
                    if not isinstance(el.tag, str):
                        continue
                    counts[etree.QName(el).localname.lower()] += 1
                    if el.get('style'):
                        inline += 1
                        declarations(tinycss2.parse_declaration_list(el.get('style'),
                                     skip_whitespace=True, skip_comments=True), name, '[inline]')
                    if etree.QName(el).localname == 'style':
                        rules(tinycss2.parse_stylesheet(el.text or '', skip_whitespace=True,
                              skip_comments=True), name + '#style')
                tags.update(counts)
                body = document.find('.//{*}body')
                docs.append({'path':name, 'textCharacters':len(''.join(body.itertext())) if body is not None else 0,
                             'elements':sum(counts.values()), 'inlineStyleElements':inline,
                             'specialTags':{k:counts[k] for k in ('ruby','rt','rp','table','svg','text','script','image') if counts[k]},
                             'bodyAttributes':dict(body.attrib) if body is not None else {},
                             'stylesheets':[local(name,x.get('href','')) for x in document.findall('.//{*}link')
                                            if 'stylesheet' in (x.get('rel') or '')]})
    result.update({'cssFiles':css_files,'fonts':fonts,'atRules':dict(ats),
                   'propertyCounts':dict(props.most_common()), 'propertyExamples':dict(samples),
                   'tagCounts':dict(tags.most_common()), 'documents':docs, 'cssParseErrors':errors,
                   'scope':'Static declarations and document structure; no computed layout or app rendering claim'})
    return result


if __name__ == '__main__':
    arg = argparse.ArgumentParser()
    arg.add_argument('books', nargs='+', type=Path)
    arg.add_argument('--output', type=Path, required=True)
    args = arg.parse_args()
    output = [audit(p) for p in args.books]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    keys = ('position','float','transform','writing-mode','-epub-writing-mode','display',
            'font-family','text-combine-upright','line-height','width','height','text-indent')
    for item in output:
        print(json.dumps({k:item[k] for k in ('file','sha256','epubVersion','spineDirection','fonts','atRules','manifestMissingFiles')}
                         | {'spineItems':len(item['spine']), 'cssFiles':len(item['cssFiles']),
                            'layoutProperties':{k:item['propertyExamples'][k] for k in keys if k in item['propertyExamples']},
                            'specialTags':{k:v for k,v in item['tagCounts'].items() if k in ('ruby','rt','rp','table','svg','script')}},
                         ensure_ascii=False, indent=2))
