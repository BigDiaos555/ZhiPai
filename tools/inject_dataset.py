#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一份数据集注入 app.html（替换里面 `const DATASET = {...};` 那一行）。

    python3 inject_dataset.py demo_dataset.json ../web/app.html
    python3 inject_dataset.py demo_dataset.json ../web/app.html -o /tmp/app.demo.html

数据集由 gen_demo_dataset.py 生成；两者配合就能重造演示版。
之所以单独做脚本而不是让网页去 fetch：单文件应用要能双击直接打开，
file:// 下 fetch 同级 JSON 会被同源策略挡掉。
"""
import json
import sys

MARK = 'const DATASET = '


def inject(dataset_path, html_path, out_path=None):
    with open(dataset_path, encoding='utf-8') as f:
        data = json.load(f)                      # 顺手校验 JSON 合法性
    payload = json.dumps(data, ensure_ascii=False, separators=(',', ':'))

    with open(html_path, encoding='utf-8') as f:
        html = f.read()

    start = html.find(MARK)
    if start < 0:
        raise SystemExit('没找到 %r，确认这是单文件版 app.html' % MARK)
    end = html.find('\n', start)
    if end < 0:
        end = len(html)
    line = html[start:end].rstrip()
    if not line.endswith('};'):
        raise SystemExit('DATASET 那一行不是以 }; 结尾，结构可能被改过，先人工看一下')

    new_html = html[:start] + MARK + payload + ';' + html[end:]
    target = out_path or html_path
    with open(target, 'w', encoding='utf-8') as f:
        f.write(new_html)
    print('注入完成 ->', target)
    print('数据 %d 条课时 / %d 名学生 / %.1f KB'
          % (len(data.get('lessons', [])),
             len(data.get('seating', {}).get('students', [])),
             len(payload) / 1024))


if __name__ == '__main__':
    import argparse

    ap = argparse.ArgumentParser(description='把数据集注入单文件版 app.html')
    ap.add_argument('dataset', help='数据集 JSON（如 demo_dataset.json）')
    ap.add_argument('html', help='目标 app.html（原地替换）')
    ap.add_argument('-o', '--out', help='输出到新文件，不改原文件')
    a = ap.parse_args()
    inject(a.dataset, a.html, a.out)
